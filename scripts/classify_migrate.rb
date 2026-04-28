# frozen_string_literal: true

# Phase 3 / 3: MIGRATE — apply the classifier's suggested moves to the DB.
#
# Usage:
#   bin/rails runner script/classify_migrate.rb --dry-run
#   bin/rails runner script/classify_migrate.rb --apply
#
# Reads:  ckb/general_classify_out.csv  (from script/classify_run.rb)
# Writes: ckb/classify_migrate_audit.csv  (rollback record: original -> new)
#
# Behavior:
#  - Topics with suggested = "stay_in_general" are skipped (no-op).
#  - Topics already moved out of General are skipped (idempotent).
#  - Topics whose suggested category doesn't exist are logged and skipped.
#  - Per-target CategoryFeaturedTopic is rebuilt once at the end (not per-move),
#    same trick as recategorize.rb to avoid unique-key collisions.

require "csv"

DRY_RUN = !ARGV.include?("--apply")
ALLOW_PARTIAL = ARGV.include?("--allow-partial")
EXTRACT_PATH = "ckb/general_classify_in.jsonl"
IN_PATH = "ckb/general_classify_out.csv"
AUDIT_PATH = "ckb/classify_migrate_audit.csv"
REVIEW_PATH = "ckb/classify_migrate_review_needed.csv"

# Confidence gate. Topics with confidence < this threshold are NOT moved — they
# stay in General and get written to REVIEW_PATH for manual triage.
# Override with `--min-confidence 0.85` etc.
threshold_idx = ARGV.index { |a| a.start_with?("--min-confidence") }
MIN_CONFIDENCE =
  if threshold_idx
    arg = ARGV[threshold_idx]
    # Accept both `--min-confidence=0.85` and `--min-confidence 0.85`. The earlier
    # `split("=").last&.to_f || next_arg.to_f` form silently collapsed the space
    # form to 0.0 (Ruby's `||` does not short-circuit on 0.0), disabling the gate.
    raw = arg.include?("=") ? arg.split("=", 2).last : ARGV[threshold_idx + 1]
    abort "Missing value for --min-confidence" if raw.nil? || raw.empty?
    unless raw.match?(/\A\d+(\.\d+)?\z/)
      abort "Invalid value for --min-confidence: #{raw.inspect} (expected a number, e.g. 0.85)"
    end
    raw.to_f
  else
    0.7
  end

VALID_TARGETS = [
  "Development",
  "Applications & Ecosystem",
  "Announcements & Meta",
  "Theory & Design",
  "Miners Pub",
  # NOTE: "Community Space" is intentionally NOT a valid migrate target. By design
  # Community Space is a container for community-applied subcategories (Spark
  # Program, CKB Community Fund DAO) — direct top-level posts are not allowed.
  # Spark Program and CKB Community Fund DAO content already gets routed via
  # tag-driven step 4 / NEST step 2 in recategorize.rb, so they never reach
  # General. If the classifier suggests "Community Space" for a remaining General
  # topic, we want it to fall into the "invalid_category" branch (script logs +
  # leaves topic in General) rather than orphan as a direct top-level post.
].freeze

abort "Input CSV not found: #{IN_PATH}" unless File.exist?(IN_PATH)

# Completeness check: every topic that was extracted must have a classification row.
# A silent partial here would leave production with un-triaged topics in General while
# the migrate script reports success. Abort unless the operator opts in via --allow-partial.
if File.exist?(EXTRACT_PATH)
  require "json"
  extracted_ids = File.foreach(EXTRACT_PATH).map { |l| JSON.parse(l)["id"].to_i }.to_set
  classified_ids = Set.new
  CSV.foreach(IN_PATH, headers: true) { |row| classified_ids << row["id"].to_i if row["id"] }
  missing_ids = extracted_ids - classified_ids
  if missing_ids.any?
    msg =
      "Classification incomplete: #{missing_ids.size} topic(s) extracted but not in #{IN_PATH}. " \
        "Re-run script/classify_run.rb (resume mode picks up where it left off), " \
        "or pass --allow-partial to proceed anyway."
    if ALLOW_PARTIAL
      warn "WARNING: #{msg}"
      warn "         Proceeding due to --allow-partial. Sample missing ids: #{missing_ids.first(10).to_a.inspect}"
    else
      abort msg + "\nFirst missing ids: #{missing_ids.first(10).to_a.inspect}"
    end
  end
else
  warn "NOTE: #{EXTRACT_PATH} not found, skipping extract/classify completeness check."
end

general = Category.find_by(name: "General", parent_category_id: nil)
abort "General category not found" unless general

# Pre-resolve all valid target categories (and abort if any are missing).
targets = {}
VALID_TARGETS.each do |name|
  cat = Category.find_by(name: name, parent_category_id: nil)
  abort "Target category not found: #{name}" unless cat
  targets[name] = cat
end

puts "*" * 70
puts " #{DRY_RUN ? "DRY RUN — no changes will be written" : "APPLY MODE — writes will happen"}"
puts "*" * 70

# Disable per-move featured-topic rebuild; we'll do it once at the end. Wrap the
# rest of the script in begin/ensure so prev_flag is restored even on exceptions
# during the CSV loop or subsequent steps.
prev_flag = Topic.update_featured_topics
Topic.update_featured_topics = false unless DRY_RUN

puts " min confidence: #{MIN_CONFIDENCE}  (rows below this stay in General, written to #{REVIEW_PATH})"

stats = Hash.new(0)
audit_rows = [] # dry-run only — apply mode streams per-row, see audit_csv below
review_rows = []
touched_target_ids = []

# In apply mode, open the audit CSV in APPEND mode and stream per move so a mid-run
# crash leaves a real (partial) rollback record on disk. Truncating with "w" at the
# end was unsafe in two ways:
#   1. Crash before the final write -> N topics moved in DB, 0 rows in audit.
#   2. Successful rerun (every topic skipped as already_moved) -> truncates the
#      previous run's audit to just the header, destroying the only rollback record.
audit_target = DRY_RUN ? "#{AUDIT_PATH}.dryrun" : AUDIT_PATH
audit_header = %w[topic_id original_category_id new_category_id new_category_name confidence title]
audit_csv = nil
unless DRY_RUN
  needs_header = !File.exist?(audit_target) || File.zero?(audit_target)
  audit_csv = CSV.open(audit_target, "a")
  audit_csv << audit_header if needs_header
  audit_csv.flush
end

begin
  CSV.foreach(IN_PATH, headers: true) do |row|
    id = row["id"].to_i
    suggested = row["suggested"].to_s.strip
    confidence = row["confidence"].to_f
    reasoning = row["reasoning"].to_s
    title = row["title"].to_s

    if suggested == "stay_in_general"
      stats[:stay] += 1
      next
    end

    if VALID_TARGETS.exclude?(suggested)
      stats[:invalid_category] += 1
      puts "  SKIP  id=#{id} unknown category #{suggested.inspect}"
      next
    end

    if confidence < MIN_CONFIDENCE
      stats[:low_confidence] += 1
      review_rows << [id, title, suggested, confidence, reasoning]
      next
    end

    topic = Topic.find_by(id: id)
    unless topic
      stats[:missing] += 1
      puts "  SKIP  id=#{id} topic not found (deleted?)"
      next
    end

    if topic.category_id != general.id
      current = Category.find_by(id: topic.category_id)
      stats[:already_moved] += 1
      puts "  SKIP  id=#{id} not in General (now in #{current&.name || "?"})"
      next
    end

    target = targets[suggested]
    action = "id=#{id} (#{topic.title[0, 50]}) -> #{suggested} (conf=#{confidence})"

    audit_row = [id, general.id, target.id, suggested, confidence, topic.title]

    if DRY_RUN
      puts "  WOULD  move #{action}"
      audit_rows << audit_row
    else
      Topic.transaction { topic.change_category_to_id(target.id, silent: true) }
      audit_csv << audit_row
      audit_csv.flush
      puts "     DO  move #{action}"
      touched_target_ids << target.id
      # General is the SOURCE — its CategoryFeaturedTopic cache is now stale (still
      # references the topic we just moved out). Rebuild it too, otherwise General's
      # category page keeps showing already-moved topics in the featured slot until
      # someone posts there.
      touched_target_ids << general.id
    end

    stats[:moved] += 1
  end

  # Rebuild CategoryFeaturedTopic once per touched target.
  unless DRY_RUN
    touched_target_ids.uniq.each do |cid|
      cat = Category.find_by(id: cid)
      next unless cat
      CategoryFeaturedTopic.where(category_id: cid).delete_all
      CategoryFeaturedTopic.feature_topics_for(cat)
      puts "  REBUILT featured topics for #{cat.name}"
    end

    # Refresh stats so topic_count reflects the moves.
    Category.update_stats

    # Push refresh to clients (same as recategorize.rb step 12).
    Site.clear_cache
    Rails.cache.clear
    Site.clear_anon_cache!
    Discourse.request_refresh!
    puts "  CLEAR  caches + push refresh to connected clients"
  end

  # Apply mode streams audit per-row (see audit_csv setup above). Dry-run writes a
  # preview file at the end with `.dryrun` suffix — never overwrites the rollback
  # record from a real apply, since they have different paths.
  if DRY_RUN
    CSV.open(audit_target, "w") do |csv|
      csv << audit_header
      audit_rows.each { |r| csv << r }
    end
    puts "  AUDIT  wrote #{audit_rows.size} rows to #{audit_target} (dry-run preview)"
  else
    puts "  AUDIT  streamed #{stats[:moved]} rows to #{audit_target}"
  end

  # Write low-confidence rows for human review (separate file, dry-run / apply share).
  if review_rows.any?
    CSV.open(REVIEW_PATH, "w") do |csv|
      csv << %w[topic_id title suggested confidence reasoning]
      review_rows.each { |r| csv << r }
    end
    puts "  REVIEW wrote #{review_rows.size} low-confidence rows to #{REVIEW_PATH}"
  end
ensure
  # Always restore — even if CSV.foreach or any of the steps above raised.
  audit_csv&.close
  Topic.update_featured_topics = prev_flag
end

puts ""
puts "Summary:"
puts "  moved:                    #{stats[:moved]}"
puts "  stayed in General:        #{stats[:stay]}"
puts "  low-confidence (review):  #{stats[:low_confidence]}"
puts "  already moved:            #{stats[:already_moved]}"
puts "  topic missing:            #{stats[:missing]}"
puts "  invalid category:         #{stats[:invalid_category]}"
puts ""
puts "Done. #{DRY_RUN ? "Re-run with --apply to execute." : "Verify in UI."}"
