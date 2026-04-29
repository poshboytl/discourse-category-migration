# frozen_string_literal: true

# Category restructure: flatten language-based categories into thematic top levels
# after the babel-united translation plugin is in place.
#
# Usage:
#   bin/rails runner script/recategorize.rb --dry-run   # report intent, no writes
#   bin/rails runner script/recategorize.rb --apply     # execute
#
# Optional flags:
#   --reset-uncategorized   rename id=1 (e.g. "Nervos Official") back to default
#                           "Uncategorized" + clear i18n override. OFF by default.
#
# Resolution is by (parent_name, child_name) — IDs differ between environments
# so the script adapts at runtime. Safe to rerun: every step is idempotent.
#
# Before running on production:
#   pg_dump discourse > /shared/backup_$(date +%Y%m%d_%H%M).sql
#
# DRY-RUN LIMITATIONS — read before relying on it as a go/no-go signal:
#   * No new categories are created → step 5's per-topic moves don't simulate;
#     summary lines still show counts and routing decisions correctly, but you
#     won't see per-topic "DO topic N -> X" output.
#   * Step 7 (DELETE empty categories) reads pre-move state, so old categories
#     show as "KEEP — not empty". Apply mode actually empties them first, then
#     deletes successfully.
#   * Step 8 (site settings) prints "WOULD" but can't compute final ID lists for
#     not-yet-created targets. The actual apply derives them at write time.
#   Use dry-run to verify validate_sources and the move/archive plan, NOT as a
#   full state preview. For full verification, restore a backup and run --apply.

DRY_RUN = !ARGV.include?("--apply")

# Opt-in: rename whatever the uncategorized category is currently named (e.g.
# "Nervos Official" with a translation override) back to the Discourse default
# "Uncategorized" + clear the i18n override. Skipped by default because it's a
# user-visible name change unrelated to the category restructure itself.
RESET_UNCATEGORIZED = ARGV.include?("--reset-uncategorized")

# -----------------------------------------------------------------------------
# Plan
# -----------------------------------------------------------------------------

NEW_TOP_LEVELS = [
  "Announcements & Meta",
  "Development",
  "Applications & Ecosystem",
  "Theory & Design",
  "Miners Pub",
  "Community Space",
  "General",
  "Archived",
]

# Target -> list of [parent_name_or_nil, source_name]. nil parent = top level.
MOVES = {
  "Development" => [
    ["中文", "CKB 开发与技术讨论"],
    ["中文", "Layer 2 开发与技术讨论"],
    ["English", "CKB Development & Technical Discussion"],
    ["English", "Layer 2 Development & Technical Discussion"],
    ["Español", "Desarrollo De CKB y Discusion Tecnica"],
  ],
  "Applications & Ecosystem" => [
    %w[中文 生态与应用],
    ["English", "Community & Ecosystem"],
    ["Español", "Comunidad y Ecosistema"],
  ],
  "Announcements & Meta" => [
    %w[中文 新闻资讯],
    ["English", "News and Announcements"],
    ["Español", "Noticias y Anuncios"],
    [nil, "Nervos Talk Renewal & Governance"],
  ],
  "Theory & Design" => [%w[中文 加密经济学], %w[Español CryptoEconomia]],
  "Miners Pub" => [%w[中文 矿工酒馆], ["English", "Miners Pub"], %w[Español Mineria]],
  "General" => [
    %w[中文 分叉广场],
    ["English", "General Discussion"],
    ["Español", "Discusion General"],
    # Direct topics on the language shells are a mixed bag — one-pot dump to General.
    [nil, "中文"],
    [nil, "English"],
    [nil, "Español"],
  ],
  # Q&A and Grants are deprecated as standalone categories. All their content
  # (recent and old) goes directly to Archived as read-only history — NOT to
  # General. Routing them through General would create zombie archived topics
  # that the LLM classifier (classify_extract.rb filters archived: false) never
  # sees, leaving them as permanent dead weight in the General bucket.
  "Archived" => [%w[English Q&A], %w[English Grants], %w[Español Grants]],
  # drainage is read_restricted (mod-only). Move its content to Staff (also
  # read_restricted) — never to public General. RENAMES (前 step 6) renames
  # 管理人员 -> Staff first, so by step 5 "Staff" resolves correctly.
  "Staff" => [[nil, "drainage"]],
}

# Sources whose topics get archived (archived: true) on move. The destination
# is determined by MOVES — these sources go to "Archived" category, so the
# topics land in dead storage AND are flagged read-only.
ARCHIVE_SOURCES = [%w[English Q&A], %w[English Grants], %w[Español Grants]]

# Existing top-level that should become child of Community Space.
NEST_UNDER_COMMUNITY_SPACE = ["CKB Community Fund DAO"]

# Upgrade tag -> subcategory under Community Space; topics with this tag move in.
TAG_TO_SUBCATEGORY = { "Spark-Program" => "Spark Program" }

# Every source we moved from should be deleted once empty. Subcategories first
# (so parent shells have no children), then top-level shells and dead categories.
DELETE_EMPTY =
  begin
    all_sources = MOVES.values.flatten(1).uniq
    subcats = all_sources.reject { |p, _| p.nil? }
    top_levels = all_sources.select { |p, _| p.nil? }
    subcats + top_levels
  end

# Renames applied BEFORE create_new_top_levels so that a category renamed here is
# found by resolve(nil, ...) in later steps and not duplicated.
RENAMES = [
  { match: { name: "管理人员", parent_category_id: nil }, to: { name: "Staff", slug: "staff" } },
  {
    match: {
      name: "Off Topic",
      parent_category_id: nil,
    },
    to: {
      name: "General",
      slug: "general",
    },
  },
]

# Language tag by source parent name.
LANG_TAG_BY_PARENT = { "中文" => "lang-zh", "English" => "lang-en", "Español" => "lang-es" }

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

def ex(action)
  puts "  #{DRY_RUN ? "WOULD" : "   DO"}  #{action}"
  yield if !DRY_RUN && block_given?
end

def header(title)
  puts ""
  puts "=" * 70
  puts " #{title}"
  puts "=" * 70
end

def resolve(parent_name, name)
  if parent_name.nil?
    Category.find_by(name: name, parent_category_id: nil)
  else
    parent = Category.find_by(name: parent_name, parent_category_id: nil)
    return nil unless parent
    Category.find_by(name: name, parent_category_id: parent.id)
  end
end

def resolve!(parent_name, name)
  cat = resolve(parent_name, name)
  raise "Source category not found: #{parent_name || "(top)"} > #{name}" unless cat
  cat
end

def system_guardian
  @system_guardian ||= Guardian.new(Discourse.system_user)
end

CategoryStub = Struct.new(:id, :name, :parent_category_id)

def find_or_create_category(name:, parent: nil, muted: false)
  existing = resolve(parent&.name, name)
  return existing if existing

  if DRY_RUN
    puts "  WOULD  create category #{parent ? "#{parent.name} > " : ""}#{name}#{muted ? " (muted default)" : ""}"
    return CategoryStub.new("(pending)", name, parent&.id)
  end

  cat =
    Category.new(
      name: name,
      color: "AB9364",
      text_color: "FFFFFF",
      user: Discourse.system_user,
      parent_category_id: parent&.id,
    )
  cat.save!
  cat
end

# -----------------------------------------------------------------------------
# Steps
# -----------------------------------------------------------------------------

# Required PG extensions. Discourse's own migration (db/migrate/20220304162250)
# enables `unaccent` — but if a DB was restored via `psql -f dump.sql` with
# ON_ERROR_STOP=0 and the extension files weren't yet on the host, the
# extension silently doesn't get created. When a script then writes to topics
# (which fires SearchIndexer using `unaccent(...)`), AR + rack-mini-profiler
# swallow the PG error, the transaction is left in an aborted state, and later
# statements fail with "current transaction is aborted". Catch this up front.
REQUIRED_PG_EXTENSIONS = %w[unaccent].freeze

def preflight!
  header "PRE-FLIGHT — required PG extensions"
  installed = DB.query_single("SELECT extname FROM pg_extension")
  missing = REQUIRED_PG_EXTENSIONS - installed
  if missing.empty?
    puts "  OK     all required extensions present: #{REQUIRED_PG_EXTENSIONS.join(", ")}"
    return
  end

  puts "  MISSING  #{missing.join(", ")}"
  missing.each do |ext|
    ex("CREATE EXTENSION IF NOT EXISTS #{ext}") { DB.exec("CREATE EXTENSION IF NOT EXISTS #{ext}") }
  end
end

def validate_sources!
  header "0. VALIDATE sources exist (fails fast on first-run misconfiguration)"
  missing = []
  found = 0
  MOVES.each do |_target, sources|
    sources.each do |(parent, name)|
      cat = resolve(parent, name)
      if cat
        found += 1
        puts "  OK     #{parent || "(top)"} > #{name}  id=#{cat.id}  topics=#{cat.topic_count}"
      else
        missing << [parent, name]
      end
    end
  end

  return puts("  All #{found} sources present.") if missing.empty?

  # If new targets already exist, we're rerunning after a (partial or full) apply;
  # missing sources are expected. Otherwise missing sources indicate a typo in MOVES.
  rerun = NEW_TOP_LEVELS.any? { |name| resolve(nil, name) }

  missing.each do |(parent, name)|
    puts "  #{rerun ? "GONE " : "MISS "}  #{parent || "(top)"} > #{name}"
  end

  if rerun
    puts "  NOTE   #{missing.size}/#{missing.size + found} sources missing; new targets exist — treating as rerun, continuing."
  else
    abort "Aborting: #{missing.size} source categories missing and no new targets exist. Check MOVES for typos."
  end
end

def create_new_top_levels
  header "1. CREATE new top-level categories"
  @targets = {}
  NEW_TOP_LEVELS.each do |name|
    existing = resolve(nil, name)
    if existing
      puts "  SKIP   #{name} already exists (id=#{existing.id})"
      @targets[name] = existing
    else
      @targets[name] = find_or_create_category(name: name)
    end
  end

  # Pre-resolve targets that come from RENAMES so MOVES iteration can find them
  # even in dry-run (where the actual rename hasn't been written). E.g. MOVES has
  # target "Staff" — in dry-run that maps to the 管理人员 category which is about
  # to be renamed.
  RENAMES.each do |r|
    next if @targets[r[:to][:name]]
    existing = resolve(r[:match][:parent_category_id], r[:match][:name])
    @targets[r[:to][:name]] = existing if existing
  end
end

def apply_category_colors
  header "1b. COLOR  set category colors from palette (idempotent — only updates mismatches)"
  CATEGORY_COLORS.each do |name, colors|
    cat = resolve(nil, name) || Category.find_by(name: name)
    unless cat
      puts "  SKIP   #{name} not found"
      next
    end
    if cat.is_a?(CategoryStub)
      puts "  WOULD  set #{name} color to ##{colors[:color]}"
      next
    end
    if cat.color == colors[:color] && cat.text_color == colors[:text_color]
      puts "  SKIP   #{name} already #{colors[:color]}/#{colors[:text_color]}"
      next
    end
    ex(
      "update #{name} (id=#{cat.id}) color #{cat.color}/#{cat.text_color} -> #{colors[:color]}/#{colors[:text_color]}",
    ) { cat.update!(colors) }
  end
end

def nest_community_fund_dao
  header "2. NEST  CKB Community Fund DAO under Community Space"
  dao = resolve(nil, "CKB Community Fund DAO")
  cs = @targets["Community Space"] || resolve(nil, "Community Space")

  return puts("  SKIP  DAO category not found") unless dao
  return puts("  SKIP  Community Space not available") unless cs

  if cs.is_a?(Category) && dao.parent_category_id == cs.id
    return puts("  SKIP  DAO (id=#{dao.id}) already nested under Community Space (id=#{cs.id})")
  end

  ex("set parent_category_id of DAO (id=#{dao.id}) -> Community Space (id=#{cs.id})") do
    dao.update!(parent_category_id: cs.id)
  end
end

def upgrade_tag_to_subcategory
  header "4. UPGRADE tag -> subcategory under Community Space"
  cs = @targets["Community Space"] || resolve(nil, "Community Space")
  TAG_TO_SUBCATEGORY.each do |tag_name, sub_name|
    tag = Tag.find_by(name: tag_name)
    unless tag
      puts "  SKIP   tag #{tag_name} not found"
      next
    end

    sub = resolve("Community Space", sub_name)
    if sub
      puts "  SKIP   subcategory #{sub_name} already exists (id=#{sub.id})"
    else
      sub = find_or_create_category(name: sub_name, parent: cs)
    end

    moved = 0
    Topic
      .where(id: TopicTag.where(tag_id: tag.id).select(:topic_id))
      .find_each do |t|
        next if t.category_id == sub&.id
        ex("move topic #{t.id} (#{t.title[0, 60]}) -> #{sub_name}") do
          t.change_category_to_id(sub.id, silent: true)
          moved += 1
        end
      end
    puts "  ->     #{moved} topics moved into #{sub_name}" unless DRY_RUN
  end
end

# Community Space is by design a CONTAINER for community-applied subcategories
# (e.g. Spark Program, CKB Community Fund DAO). New top-level posts directly under
# Community Space are not allowed — they should live in a subcategory.
#
# Two enforcements applied here:
#   (a) Move any existing direct top-level topics (excluding the auto description
#       "About the Community Space category") to General. These typically arrive
#       from classify_migrate.rb suggesting "Community Space" for community
#       announcements / events / quarterly reports that don't have a clear
#       subcategory home — those belong in General until a subcategory is created.
#   (b) Add a CategoryGroup row: everyone (group_id=0) -> create_post (level 2).
#       This blocks creation of new top-level topics in Community Space via UI/API
#       while leaving existing subcategories' permissions untouched (subcategory
#       permissions are independent of parent in Discourse).
def lock_community_space_to_subcategories_only
  header "4b. LOCK Community Space top-level — container only (subcategories accept posts)"
  cs = @targets["Community Space"] || resolve(nil, "Community Space")
  if !cs || cs.is_a?(CategoryStub)
    puts "  SKIP   Community Space unavailable (dry-run or not yet created)"
    return
  end

  general = @targets["General"] || resolve(nil, "General")

  # (a) Relocate any direct top-level topics to General, preserving the description topic.
  desc_id = cs.topic_id
  direct_scope = Topic.unscoped.where(category_id: cs.id)
  direct_scope = direct_scope.where.not(id: desc_id) if desc_id
  count = direct_scope.count
  if count.zero?
    puts "  SKIP   no direct top-level topics to relocate"
  elsif !general || general.is_a?(CategoryStub)
    puts "  SKIP   General unavailable as relocation target"
  else
    puts "  RELOC #{count} direct top-level topics: Community Space -> General"
    direct_scope.find_each do |t|
      deleted_marker = t.deleted_at ? " [soft-deleted]" : ""
      ex("  topic #{t.id} -> General#{deleted_marker}") do
        if t.deleted_at
          t.update_columns(category_id: general.id, updated_at: Time.zone.now)
        else
          t.change_category_to_id(general.id, silent: true)
        end
      end
    end
  end

  everyone_group_id = Group::AUTO_GROUPS[:everyone] # 0
  create_post_level = CategoryGroup.permission_types[:create_post] # 2
  full_level = CategoryGroup.permission_types[:full] # 1

  # (b1) Lock the parent: everyone -> create_post (no new topics, can still see/reply).
  # CategoryGroup with permission_type=2 (create_post). Idempotent on rerun.
  existing = CategoryGroup.find_by(category_id: cs.id, group_id: everyone_group_id)
  if existing && existing.permission_type == create_post_level
    puts "  SKIP   Community Space already locked (everyone -> create_post)"
  elsif existing
    ex(
      "update CategoryGroup row: everyone -> create_post (was permission_type=#{existing.permission_type})",
    ) { existing.update!(permission_type: create_post_level) }
  else
    ex("insert CategoryGroup row: Community Space + everyone -> create_post") do
      CategoryGroup.create!(
        category_id: cs.id,
        group_id: everyone_group_id,
        permission_type: create_post_level,
      )
    end
  end

  # (b2) Subcategories need their OWN explicit category_groups. Discourse enforces
  # permission inheritance — a subcategory cannot grant MORE permission than its
  # parent unless it has an explicit row. Without this, the parent's `create_post`
  # (no new topic) restriction cascades to subcategories, blocking exactly what
  # we want to enable. Set `everyone -> full (1)` on each subcategory to override.
  Category
    .where(parent_category_id: cs.id)
    .each do |sub|
      sub_existing = CategoryGroup.find_by(category_id: sub.id, group_id: everyone_group_id)
      if sub_existing && sub_existing.permission_type == full_level
        puts "  SKIP   subcategory #{sub.name} already has everyone -> full"
      elsif sub_existing
        ex(
          "update CategoryGroup for #{sub.name}: permission_type=#{sub_existing.permission_type} -> full(1)",
        ) { sub_existing.update!(permission_type: full_level) }
      else
        ex("insert CategoryGroup row: #{sub.name} + everyone -> full(1)") do
          CategoryGroup.create!(
            category_id: sub.id,
            group_id: everyone_group_id,
            permission_type: full_level,
          )
        end
      end
    end
end

def tag_topics_with_language
  header "3. TAG   topics with language tag (direct TopicTag insert — bypasses per-category tag whitelists)"
  LANG_TAG_BY_PARENT.each do |parent_name, tag_name|
    parent = resolve(nil, parent_name)
    next unless parent
    subcat_ids = Category.where(parent_category_id: parent.id).pluck(:id) + [parent.id]
    scope = Topic.where(category_id: subcat_ids, deleted_at: nil)
    puts "  TAG    #{scope.count} topics under #{parent_name} -> ##{tag_name}"

    tag = Tag.find_by(name: tag_name)
    if tag.nil?
      if DRY_RUN
        puts "  WOULD  create tag ##{tag_name}"
      else
        tag = Tag.create!(name: tag_name)
      end
    end

    existing_topic_ids = tag ? TopicTag.where(tag_id: tag.id).pluck(:topic_id).to_set : Set.new
    scope.find_each do |t|
      next if existing_topic_ids.include?(t.id)
      # Raw INSERT bypasses TopicTag's after_create callback that fires
      # Tag.update_counters(tag.id, ...). The callback maintains denormalized
      # counters (staff_topic_count, public_topic_count, category_tag_stats)
      # which we recompute correctly via Tag.ensure_consistency! in step 11
      # and Category.update_stats. Skipping the callback also dodges a
      # phantom "tag.id for nil" issue in some dev environments.
      ex("  topic #{t.id} += ##{tag_name}") { DB.exec(<<~SQL, topic_id: t.id, tag_id: tag.id) }
          INSERT INTO topic_tags (topic_id, tag_id, created_at, updated_at)
          VALUES (:topic_id, :tag_id, now(), now())
          ON CONFLICT (topic_id, tag_id) DO NOTHING
        SQL
    end
  end
end

AGE_ARCHIVE_TARGETS = ["Announcements & Meta", "General"].freeze
AGE_ARCHIVE_CUTOFF_YEARS = 2

def move_and_archive_topics
  header "5. MOVE topics to new top-level categories; ARCHIVE where applicable"
  archive_src_ids = ARCHIVE_SOURCES.map { |p, n| resolve(p, n)&.id }.compact.to_set
  age_cutoff = AGE_ARCHIVE_CUTOFF_YEARS.years.ago
  archive_cat = @targets["Archived"] || resolve(nil, "Archived")

  # Disable per-move CategoryFeaturedTopic refresh — it fires on every topic move and
  # hits a unique-key collision on (category_id, topic_id) after the first few moves
  # into the same target. We'll rebuild featured topics once per target after the loop.
  prev_flag = Topic.update_featured_topics
  Topic.update_featured_topics = false unless DRY_RUN

  touched_target_ids = []
  MOVES.each do |target_name, sources|
    target = @targets[target_name] || resolve(nil, target_name)
    unless target
      puts "  SKIP   target #{target_name} unavailable"
      next
    end
    age_redirect_target = AGE_ARCHIVE_TARGETS.include?(target_name)

    sources.each do |(parent, name)|
      src = resolve(parent, name)
      next unless src
      # Use Topic.unscoped — Topic includes Trashable, whose default_scope hides
      # soft-deleted (deleted_at NOT NULL) topics. Without unscoped, deleted topics
      # silently stay in the source category; step 7 then sees an "empty" category,
      # destroys it, and leaves the soft-deleted topics with a dangling category_id
      # that breaks the admin "deleted topics" view.
      src_scope = Topic.unscoped.where(category_id: src.id)
      count = src_scope.count
      should_archive_all = archive_src_ids.include?(src.id)

      if age_redirect_target && archive_cat && count > 0
        old_count = src_scope.where("COALESCE(bumped_at, created_at) < ?", age_cutoff).count
        recent_count = count - old_count
        puts "  MOVE   #{count} topics: #{parent || "(top)"} > #{name}  ->  #{recent_count} to #{target_name}, #{old_count} to Archive (+archive by 2yr rule)"
      else
        puts "  MOVE   #{count} topics: #{parent || "(top)"} > #{name}  ->  #{target_name}#{should_archive_all ? "  (+ARCHIVE)" : ""}"
      end
      next if count.zero?
      next if target.is_a?(CategoryStub) # dry-run: summary only, no per-topic simulation

      touched_target_ids << target.id
      touched_target_ids << archive_cat.id if age_redirect_target && archive_cat

      src_scope.find_each do |t|
        actual_target = target
        archive_this = should_archive_all

        if age_redirect_target && archive_cat
          bumped = t.bumped_at || t.created_at
          if bumped && bumped < age_cutoff
            actual_target = archive_cat
            archive_this = true
          end
        end

        deleted_marker = t.deleted_at ? " [soft-deleted]" : ""
        ex(
          "  topic #{t.id} -> #{actual_target.name}#{archive_this ? " + archive" : ""}#{deleted_marker}",
        ) do
          if t.deleted_at
            # Soft-deleted topics: just relocate the foreign key. Skip change_category_to_id
            # which fires MessageBus events, featured-topic recompute, etc. — all aimed at
            # live topics. We only need the FK moved so step 7's destroy doesn't orphan it.
            t.update_columns(
              category_id: actual_target.id,
              archived: archive_this ? true : t.archived,
              updated_at: Time.zone.now,
            )
          else
            # No outer transaction — change_category_to_id has its own Topic.transaction
            # internally, and an outer wrap with savepoints has been observed to leave
            # the connection in "transaction aborted" state on this dev environment.
            t.update!(archived: true) if archive_this && !t.archived
            t.change_category_to_id(actual_target.id, silent: true)
          end
        end
      end
    end
  end

  # Rebuild featured topics once per target — skipped per-move above.
  unless DRY_RUN
    touched_target_ids.uniq.each do |cid|
      cat = Category.find_by(id: cid)
      next unless cat
      ex("rebuild CategoryFeaturedTopic for #{cat.name}") do
        CategoryFeaturedTopic.where(category_id: cid).delete_all
        CategoryFeaturedTopic.feature_topics_for(cat)
      end
    end
  end
ensure
  Topic.update_featured_topics = prev_flag
end

def rename_categories
  header "6. RENAME categories"
  RENAMES.each do |r|
    cat = Category.find_by(r[:match])
    unless cat
      puts "  SKIP   no match for #{r[:match].inspect}"
      next
    end
    ex("rename id=#{cat.id}  #{cat.name}/#{cat.slug} -> #{r[:to][:name]}/#{r[:to][:slug]}") do
      cat.update!(r[:to])
    end
  end
end

def migrate_uncat_stragglers_to_archived
  header "6b. MIGRATE leftover archived topics from uncategorized -> Archived (compat with prior script versions)"
  archived_cat = @targets["Archived"] || resolve(nil, "Archived")
  unless archived_cat && !archived_cat.is_a?(CategoryStub)
    return puts("  SKIP   Archived category not available")
  end

  uncat_id = SiteSetting.uncategorized_category_id
  return puts("  SKIP   uncategorized is Archived itself (no-op)") if uncat_id == archived_cat.id

  # An earlier version of this script stuffed age-archived topics into the uncategorized
  # category. Move any archived topics still sitting there into the new Archived category.
  stragglers = Topic.where(category_id: uncat_id, archived: true, deleted_at: nil)
  count = stragglers.count
  if count.zero?
    puts "  SKIP   no archived topics stuck in uncategorized"
    return
  end

  ex(
    "bulk-move #{count} archived topics: uncategorized (id=#{uncat_id}) -> Archived (id=#{archived_cat.id})",
  ) { stragglers.update_all(category_id: archived_cat.id, updated_at: Time.zone.now) }
end

def reset_uncategorized_to_default
  header "6c. RESET uncategorized back to Discourse defaults (clear i18n override + name)"
  unless RESET_UNCATEGORIZED
    puts "  SKIP   not running by default — admin's customized uncategorized name preserved."
    puts "         Pass --reset-uncategorized to opt in (renames id=1 to 'Uncategorized')."
    return
  end

  cat = Category.find_by(id: SiteSetting.uncategorized_category_id)
  unless cat
    return(
      puts("  SKIP   uncategorized category id=#{SiteSetting.uncategorized_category_id} not found")
    )
  end

  if cat.name == "Uncategorized" && cat.slug == "uncategorized"
    puts "  SKIP   uncategorized already at defaults"
  else
    ex("rename id=#{cat.id}  #{cat.name}/#{cat.slug} -> Uncategorized/uncategorized") do
      cat.update!(name: "Uncategorized", slug: "uncategorized")
    end
  end

  overrides = TranslationOverride.where(translation_key: "uncategorized_category_name")
  override_count = overrides.count
  if override_count.zero?
    puts "  SKIP   no translation_override for uncategorized_category_name"
  else
    # TranslationOverride.revert! handles per-row destroy + I18n.reload + MessageBus
    # invalidation across workers (delete_all would skip those side effects and
    # leave the customized name cached in worker memory until restart).
    locales = overrides.distinct.pluck(:locale)
    ex("TranslationOverride.revert! for #{override_count} rows across #{locales.size} locales") do
      locales.each { |loc| TranslationOverride.revert!(loc, ["uncategorized_category_name"]) }
    end
  end
end

def delete_empty_sources
  header "7. DELETE emptied categories (only if no non-description topics and no children)"
  # Description topics ("About the X category") of deleted categories are dead history.
  # Send them to Archived so the LLM classifier does not pick them up as content.
  # Exception: if the source category was read_restricted (e.g. drainage / mod-only),
  # its description belongs in Staff — moving to public Archived would leak.
  archived_target = @targets["Archived"] || resolve(nil, "Archived")
  staff_target = resolve(nil, "Staff")
  DELETE_EMPTY.each do |(parent, name)|
    cat = resolve(parent, name)
    next puts("  SKIP   #{name} not found (already deleted?)") unless cat

    cat.reload

    children = Category.where(parent_category_id: cat.id)
    # Topic.unscoped — count soft-deleted topics too. Step 5 should have moved them
    # via its own unscoped iteration; this check here is the defensive net that
    # refuses to destroy a category if anything (live or deleted) is still pointing
    # at it. Destroying with deleted topics still attached creates dangling
    # category_id FKs that break Discourse's "deleted topics" admin view.
    remaining_topics = Topic.unscoped.where(category_id: cat.id)
    remaining_topics = remaining_topics.where.not(id: cat.topic_id) if cat.topic_id

    if remaining_topics.exists? || children.exists?
      live = remaining_topics.where(deleted_at: nil).count
      deleted = remaining_topics.where.not(deleted_at: nil).count
      puts "  KEEP   #{name}  live=#{live} soft-deleted=#{deleted}  children=#{children.count}  (not empty)"
      next
    end

    # Description topic ("About the X category") is protected from change_category_to_id
    # by topic.rb:1063 (Category.exists?(topic_id: id) short-circuit). Unlink first so
    # it can be moved, then shunt to Archived (or Staff if source was private).
    if cat.topic_id
      desc_dest =
        if cat.read_restricted && staff_target
          staff_target
        elsif archived_target && !archived_target.is_a?(CategoryStub)
          archived_target
        end
      if desc_dest
        desc_topic_id = cat.topic_id
        ex("unlink + move description topic #{desc_topic_id} to #{desc_dest.name} for #{name}") do
          cat.update_columns(topic_id: nil)
          desc = Topic.find_by(id: desc_topic_id)
          if desc
            # Unpin + unlist so these orphaned 'About the X category' topics don't
            # clutter the destination category's top. They are dead history of a
            # category we are about to destroy.
            desc.update!(
              archived: (desc.archived || desc_dest != staff_target),
              pinned_at: nil,
              pinned_globally: false,
              visible: false,
            )
            desc.change_category_to_id(desc_dest.id, silent: true)
          end
        end
      end
    end

    ex("destroy category id=#{cat.id} name=#{name}") { cat.destroy! }
  end
end

DEFAULT_SIDEBAR_CATEGORIES = [
  "Announcements & Meta",
  "Development",
  "Applications & Ecosystem",
  "Theory & Design",
  "Miners Pub",
  "Community Space",
].freeze

ARCHIVE_AGE_YEARS = 2
# Step 10's age-archive operates ONLY on categories where old content has limited
# reference value: chatter, news, events. Knowledge-base categories (Development,
# Theory & Design, Applications & Ecosystem) are deliberately excluded — a 2-year-old
# technical thread often retains value as someone may want to follow up or correct it.
# Source categories that step 7 will delete (e.g. "News and Announcements") are also
# included so their old residue gets archived before deletion takes their topics
# along to the new home.
ARCHIVE_AGE_INCLUDE_CATEGORY_NAMES = [
  "General",
  "Announcements & Meta",
  "Community Space",
  "Miners Pub",
  "Archived",
].freeze

CATEGORY_COLORS = {
  "Announcements & Meta" => {
    color: "BF1E2E",
    text_color: "FFFFFF",
  },
  "Development" => {
    color: "3498DB",
    text_color: "FFFFFF",
  },
  "Applications & Ecosystem" => {
    color: "2ECC71",
    text_color: "FFFFFF",
  },
  "Theory & Design" => {
    color: "9B59B6",
    text_color: "FFFFFF",
  },
  "Miners Pub" => {
    color: "8B4513",
    text_color: "FFFFFF",
  },
  "Community Space" => {
    color: "F39C12",
    text_color: "FFFFFF",
  },
  "General" => {
    color: "95A5A6",
    text_color: "FFFFFF",
  },
  "Spark Program" => {
    color: "E67E22",
    text_color: "FFFFFF",
  },
  "Archived" => {
    color: "34495E",
    text_color: "FFFFFF",
  },
}.freeze

def update_site_settings
  header "8. SITE SETTINGS (backfills CategoryUser / SidebarSectionLink for existing users)"
  puts "  NOTE   Changing these triggers Discourse's SiteSettingUpdateExistingUsers service,"
  puts "         which batch-upserts rows for every real user. Schedule during a quiet window."

  # 8a. Ensure General is NOT in default_categories_muted — muting a category in
  # Discourse hides it from BOTH Latest feed and the Categories index page (there is
  # no longer a per-category "suppress_from_latest" flag, that was removed in 2019).
  # We want General discoverable on /categories and its new posts on /latest.
  general = @targets["General"] || resolve(nil, "General")
  if !general || general.is_a?(CategoryStub)
    puts "  SKIP   General unavailable for default_categories_muted cleanup"
  else
    current = (SiteSetting.default_categories_muted || "").split("|").reject(&:empty?).map(&:to_i)
    if !current.include?(general.id)
      puts "  SKIP   General (id=#{general.id}) already absent from default_categories_muted"
    else
      new_value = (current - [general.id]).join("|")
      ex(
        "SiteSetting.default_categories_muted = #{new_value.inspect}  (was #{SiteSetting.default_categories_muted.inspect})",
      ) { SiteSetting.default_categories_muted = new_value }
    end
    # User-level CategoryUser mute rows on General are intentionally NOT touched.
    # We can't distinguish a user's manual mute from a row a prior version of this
    # script may have backfilled, and silently deleting real preferences is worse
    # than leaving a few stale auto-mute rows behind. The site setting change above
    # is sufficient for new users — existing per-user rows stay as-is.
  end

  # 8b. Default sidebar categories (Archived deliberately excluded — dead storage)
  sidebar_cats = DEFAULT_SIDEBAR_CATEGORIES.map { |n| @targets[n] || resolve(nil, n) }
  if sidebar_cats.any?(&:nil?)
    puts "  SKIP   default_navigation_menu_categories (some target categories not found)"
  elsif sidebar_cats.any? { |c| c.is_a?(CategoryStub) }
    puts "  WOULD  SiteSetting.default_navigation_menu_categories = (new ids once created)"
  else
    want = sidebar_cats.map(&:id).join("|")
    got = SiteSetting.default_navigation_menu_categories.to_s
    if got == want
      puts "  SKIP   default_navigation_menu_categories already = #{want}"
    else
      ex(
        "SiteSetting.default_navigation_menu_categories = #{want.inspect}  (was #{got.inspect})",
      ) { SiteSetting.default_navigation_menu_categories = want }
    end
  end

  # 8c. Archived should be muted — hides from Latest feed AND Categories index page.
  # Accessible only by direct URL or admin panel.
  archived = @targets["Archived"] || resolve(nil, "Archived")
  if !archived || archived.is_a?(CategoryStub)
    puts "  SKIP   Archived unavailable for default_categories_muted"
  else
    current = (SiteSetting.default_categories_muted || "").split("|").reject(&:empty?).map(&:to_i)
    if current.include?(archived.id)
      puts "  SKIP   Archived (id=#{archived.id}) already in default_categories_muted"
    else
      new_value = (current + [archived.id]).uniq.join("|")
      ex(
        "SiteSetting.default_categories_muted = #{new_value.inspect}  (was #{SiteSetting.default_categories_muted.inspect})",
      ) { SiteSetting.default_categories_muted = new_value }
    end
  end
end

def cleanup_orphans
  header "9. CLEANUP orphan CategoryUser rows (categories deleted from under them)"
  count = CategoryUser.where.not(category_id: Category.select(:id)).count
  if count.zero?
    puts "  SKIP   no orphan category_users rows"
  else
    ex("delete #{count} orphan category_users rows") do
      CategoryUser.where.not(category_id: Category.select(:id)).delete_all
    end
  end
end

def archive_stale_topics
  header "10. ARCHIVE topics with no activity for #{ARCHIVE_AGE_YEARS}+ years"
  cutoff = ARCHIVE_AGE_YEARS.years.ago

  # Resolve included categories (and their subcategories — e.g. Community Space's
  # children like Spark Program inherit the chatter/event semantics).
  parent_ids = ARCHIVE_AGE_INCLUDE_CATEGORY_NAMES.map { |n| resolve(nil, n)&.id }.compact
  if parent_ids.empty?
    puts "  SKIP   none of the include-list categories exist yet (#{ARCHIVE_AGE_INCLUDE_CATEGORY_NAMES.join(", ")})"
    return
  end

  child_ids = Category.where(parent_category_id: parent_ids).pluck(:id)
  included_ids = (parent_ids + child_ids).uniq

  resolved_names = Category.where(id: included_ids).order(:id).pluck(:name)
  puts "  SCOPE  archiving in: #{resolved_names.join(", ")}"
  puts "  SCOPE  NOT archiving in: Development, Theory & Design, Applications & Ecosystem, Staff (knowledge-base content stays open for follow-ups)"

  scope =
    Topic
      .where(archetype: "regular", archived: false, deleted_at: nil)
      .where(category_id: included_ids)
      .where("COALESCE(bumped_at, created_at) < ?", cutoff)

  total = scope.count
  puts "  FOUND  #{total} topics with no activity since #{cutoff.to_date}"
  return puts("  SKIP   nothing to archive") if total.zero?

  ex("archive #{total} topics in one bulk update") do
    scope.update_all(archived: true, updated_at: Time.zone.now)
  end
end

def refresh_stats
  header "11. REFRESH Category.update_stats + Tag.ensure_consistency!"
  ex("Category.update_stats") { Category.update_stats }
  ex("Tag.ensure_consistency!  (recompute topic_count after direct TopicTag inserts)") do
    Tag.ensure_consistency!
  end
end

def clear_caches_and_push_refresh
  header "12. CLEAR Rails/Redis caches + push refresh to connected clients"
  # Site.clear_cache deletes Discourse.cache's categories_cache_key (the Redis-backed
  # categories snapshot that /site.json reads). Rails.cache is a SEPARATE instance;
  # clearing it alone doesn't touch Discourse.cache.
  ex("Site.clear_cache  (wipes Discourse.cache categories snapshot)") { Site.clear_cache }
  ex("Rails.cache.clear  (wipes fragment caches backed by Redis)") { Rails.cache.clear }
  ex("Site.clear_anon_cache!  (bump /site.json sequence)") { Site.clear_anon_cache! }
  ex("Category.reset_topic_ids_cache") { Category.reset_topic_ids_cache }
  ex("Discourse.request_refresh!  (MessageBus: tells all connected clients to reload)") do
    Discourse.request_refresh!
  end
end

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------

puts ""
puts "*" * 70
puts " #{DRY_RUN ? "DRY RUN — no changes will be written" : "APPLY MODE — writes will happen"}"
puts "*" * 70

preflight!
validate_sources!
rename_categories
create_new_top_levels
apply_category_colors
nest_community_fund_dao
tag_topics_with_language
upgrade_tag_to_subcategory
lock_community_space_to_subcategories_only
move_and_archive_topics
migrate_uncat_stragglers_to_archived
reset_uncategorized_to_default
delete_empty_sources
update_site_settings
cleanup_orphans
archive_stale_topics
refresh_stats
clear_caches_and_push_refresh

puts ""
puts "Done. #{DRY_RUN ? "Re-run with --apply to execute." : "Verify in UI; rollback with pg restore if needed."}"
