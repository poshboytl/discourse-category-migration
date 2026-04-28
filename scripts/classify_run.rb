# frozen_string_literal: true

# Phase 2 / 3: CLASSIFY — ask Claude Sonnet 4.6 where each General topic should go.
#
# Usage:
#   ruby script/classify_run.rb
#
# Reads:  ckb/general_classify_in.jsonl   (from script/classify_extract.rb)
# Writes: ckb/general_classify_out.csv    (append-mode, resumable)
# Key:    env ANTHROPIC_API_KEY, or ckb/.anthropic_key
#
# Features:
#  - Prompt caching on the rubric (cache_control: ephemeral) — ~90% cost reduction
#    on cached input tokens after the first call.
#  - Structured JSON output via output_config.format json_schema — model CANNOT
#    return malformed JSON or an unknown category.
#  - Resumable: on restart, skips any id already present in the output CSV.
#  - Exponential backoff on 429/5xx.

require "net/http"
require "uri"
require "json"
require "csv"

MODEL = "claude-sonnet-4-6"
IN_PATH = "ckb/general_classify_in.jsonl"
OUT_PATH = "ckb/general_classify_out.csv"
KEY_PATH = "ckb/.anthropic_key"
MAX_TOKENS = 400
MAX_RETRIES = 4
REQUEST_TIMEOUT_SEC = 60

ANTHROPIC_API_KEY =
  ENV["ANTHROPIC_API_KEY"] || (File.exist?(KEY_PATH) ? File.read(KEY_PATH).strip : nil)
if ANTHROPIC_API_KEY.nil? || ANTHROPIC_API_KEY.empty?
  abort "API key missing — set ANTHROPIC_API_KEY env or write #{KEY_PATH}"
end

# Raised by call_claude on HTTP 401/403. Caught at the top level so the script
# exits immediately on auth failure instead of plowing through every remaining
# topic with the same dead key (which produces useless API calls and a wall of
# duplicate FAIL log lines).
class AuthError < StandardError
end

# ---------------------------------------------------------------------------
# RUBRIC — sent once per request as the cached system prompt.
# Must be ≥ 2048 tokens for Sonnet 4.6 caching to kick in; keep it detailed.
# ---------------------------------------------------------------------------

RUBRIC = <<~PROMPT
  You are a classifier for Nervos Talk, a blockchain community forum with posts in English, Chinese (Simplified), and Spanish.

  The forum has 6 topical buckets. For each topic you are given, pick EXACTLY ONE of:

    1. Development
    2. Applications & Ecosystem
    3. Announcements & Meta
    4. Theory & Design
    5. Miners Pub
    6. stay_in_general   (the default when unsure)

  NOTE: "Community Space" is a parent CONTAINER for community-applied subcategories
  (e.g. Spark Program, CKB Community Fund DAO). It does NOT accept direct top-level
  posts. Spark Program / DAO content is auto-routed via tags and category nesting,
  so it never reaches this classifier. Do NOT suggest "Community Space" — for
  community announcements / events / programs that lack a specific subcategory home,
  use stay_in_general (the operator will hand-triage them later).

  Output a single JSON object matching the provided schema. No prose before or after.

  ---

  ## Category Boundaries

  ### 1. Development
  Discussion of the CKB protocol, CKB-VM, Layer 2 protocols (Godwoken, Axon, Fiber), RFCs, consensus mechanisms at the implementation level, dev tooling, SDK internals, protocol-level proposals. "How the chain works / should work" rather than "how to use a product built on it".

  Positive examples:
  - "RFC: Extensible ECDSA lock script"
  - "CKB-VM riscv32 instruction audit"
  - "Proposal: change block interval to 12s"
  - "Light client sync protocol — edge cases with reorgs"
  - "Godwoken v1 state tree benchmarks"

  NOT Development:
  - "My Portal Wallet won't connect to MetaMask" → Applications & Ecosystem
  - "Tokenomics: is 1 CKB = 1 Byte optimal?" → Theory & Design
  - "Spark Program grant for a wallet project" → stay_in_general (operator will triage to Community Space subcategory)

  ### 2. Applications & Ecosystem
  Specific end-user products built on CKB or adjacent: wallets (Neuron, Portal Wallet, JoyID, OneKey, ckbull), dapps, bridges, exchanges (listings, withdrawals), integrations, SDK usage for a specific product, infrastructure-operator questions (running a node, monitoring, deployment). Bug reports and feature requests for specific products go here. User-facing tutorials.

  Positive examples:
  - "JoyID passkey recovery flow"
  - "How do I set up a CKB mainnet node on Raspberry Pi?"
  - "CCC SDK v0.3 — breaking change for React hooks"
  - "Mexc exchange stuck withdrawal"
  - "Portal Wallet MetaMask signing fails on Firefox"
  - "Announcing: NewDapp launches on CKB testnet"

  NOT Applications & Ecosystem:
  - "CKB-VM semantics of VM version 2" → Development
  - "Should we add on-chain KYC?" → Theory & Design / stay_in_general
  - "Spark grant announcement for wallet X" → stay_in_general (a grant announcement belongs in a Community Space subcategory; operator routes it post-classification)

  ### 3. Announcements & Meta
  ONLY forum-level material. Official announcements from forum admins about the FORUM ITSELF. Meta-discussion about forum rules, forum moderation, forum software, forum features.

  CRUCIALLY NOT for DAO governance, Nervos Foundation governance, or any protocol/ecosystem governance discussion. Those go to stay_in_general.

  Positive examples:
  - "Forum upgrade to Discourse 3.5 this Saturday"
  - "New posting rules effective 2026-05-01"
  - "Who are the current moderators?"
  - "Announcing babel-united translation plugin"

  NOT Announcements & Meta:
  - "DAO V2 governance proposal discussion" → stay_in_general
  - "Nervos Foundation roadmap clarifications needed" → stay_in_general
  - "CKB ecosystem update: Q1 partnerships" → stay_in_general (or Applications & Ecosystem if it's a specific app launch)
  - "Spark Program Q2 opens for applications" → stay_in_general (the operator will route program content into the Community Space > Spark Program subcategory)

  The word "governance" alone is a trap. Ask: is this governance OF THE FORUM (rules, mods, features)? → Meta. Is this governance OF THE PROTOCOL / DAO / FOUNDATION? → NOT Meta (usually stay_in_general).

  ### 4. Theory & Design
  Protocol research, tokenomics theory, consensus mechanism analysis, economic model debates, philosophical takes on blockchain design tradeoffs, academic-style write-ups, deep-dive critiques. Not "how it works" but "why it is the way it is and should it be different".

  Positive examples:
  - "Rethinking NervosDAO issuance curve in a world with L2 fees"
  - "Is Cell model truly superior to Account model? A survey"
  - "Game-theoretic analysis of secondary issuance"
  - "Why 8 CKB minimum deposit is too high for microtransactions"

  NOT Theory & Design:
  - "RFC: Change issuance formula" → Development (concrete proposal)
  - "How does NervosDAO work?" → Applications & Ecosystem (user-facing explainer)

  ### 5. Miners Pub
  Anything mining-specific: hardware (ASICs, GPUs), pools, profitability, rigs, power/heat, mining software, casual miner chat, solo-mining experiences. If a miner is talking shop, it goes here.

  Positive examples:
  - "Goldshell CK-BOX2 review"
  - "SparkPool shutdown — migrating to which pool?"
  - "CKB vs BTM profitability in 2026"
  - "PSU recommendations for 10 KD5 rigs"

  NOT Miners Pub:
  - "NC-Max consensus mechanism critique" → Theory & Design
  - "Mining pool API integration for Neuron" → Applications & Ecosystem

  ### 6. stay_in_general  ← DEFAULT
  Legitimate default bucket. Use when:
  - Personal posts, farewells, rants, venting, opinions
  - DAO governance / protocol governance / foundation governance DISCUSSIONS (as opposed to announcements)
  - Community programs / events / grant announcements / Spark Program / Fund DAO content that lacks a specific subcategory home (operator will route these into Community Space subcategories post-classification)
  - Mixed content that spans categories
  - Short threads without clear topical signal ("lol", "gm", "what do you think?")
  - Market / price / speculation chatter
  - Memes, off-topic fun
  - Any topic where the best other category is below ~0.7 confidence

  Examples that belong in stay_in_general:
  - "告别 - 祝一切顺利" (farewell post)
  - "Do you think DAO V1.1 voting period should be longer?" (protocol governance opinion)
  - "BTC ATH coming — what's CKB's pitch to new users?"
  - "What are people's thoughts on the foundation's transparency?"
  - "随便聊聊" ("just chatting")

  ---

  ## Decision rules

  1. **stay_in_general is a first-class valid answer.** Do not force a topic into a category when uncertain. Prefer stay_in_general.

  2. **The word "governance" is NOT a Meta signal by default.** Re-read: is this about FORUM governance (rules, mods, plugins)? Only then is it Meta. Protocol/DAO/Foundation governance → stay_in_general.

  3. **Ambiguity between two topical categories → stay_in_general.** Don't guess.

  4. **Language doesn't matter.** zh/en/es content is equally valid; classify on substance.

  5. **Title vs body conflict.** Weigh the body more heavily than the title; clickbait titles mislead.

  6. **Implicit tests.** If a topic is a general-interest poll ("what do you all think?") with no strong topical hook, stay_in_general.

  ---

  ## Confidence scale

  Report confidence 0.0–1.0:
  - 0.90+  : clearly this category, strong explicit signal
  - 0.70–0.89 : most likely this category
  - 0.50–0.69 : leaning this way but uncertain — at this range, consider flipping to stay_in_general
  - <0.50 : you should probably have chosen stay_in_general

  Write reasoning as ONE short sentence — the signal you keyed on (e.g. "Specific to Neuron wallet", "DAO governance discussion, not forum meta", "Farewell post, no topical content").

  Return ONLY the JSON object. No markdown, no prose, no preamble.
PROMPT

# Output schema — model is constrained to this.
# NOTE: Anthropic json_schema does not accept numerical (minimum/maximum) or
# string-length (maxLength) constraints. Ranges are enforced via the rubric.
SCHEMA = {
  type: "object",
  properties: {
    suggested: {
      type: "string",
      enum: [
        "Development",
        "Applications & Ecosystem",
        "Announcements & Meta",
        "Theory & Design",
        "Miners Pub",
        "stay_in_general",
      ],
    },
    confidence: {
      type: "number",
    },
    reasoning: {
      type: "string",
    },
  },
  required: %w[suggested confidence reasoning],
  additionalProperties: false,
}.freeze

# ---------------------------------------------------------------------------
# HTTP — one Claude API call with retry.
# ---------------------------------------------------------------------------

def call_claude(title:, body:, lang:, reply_count:)
  uri = URI("https://api.anthropic.com/v1/messages")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = REQUEST_TIMEOUT_SEC
  http.open_timeout = 10

  user_content = +""
  user_content << "Title: #{title}\n"
  user_content << "Language tag: #{lang || "(none)"}\n"
  user_content << "Replies: #{reply_count}\n\n"
  user_content << "Body:\n#{body}"

  payload = {
    model: MODEL,
    max_tokens: MAX_TOKENS,
    system: [{ type: "text", text: RUBRIC, cache_control: { type: "ephemeral" } }],
    output_config: {
      format: {
        type: "json_schema",
        schema: SCHEMA,
      },
    },
    messages: [{ role: "user", content: user_content }],
  }

  MAX_RETRIES.times do |attempt|
    req = Net::HTTP::Post.new(uri.path)
    req["x-api-key"] = ANTHROPIC_API_KEY
    req["anthropic-version"] = "2023-06-01"
    req["content-type"] = "application/json"
    req.body = payload.to_json

    begin
      resp = http.request(req)
    rescue Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET, EOFError => e
      wait = 2**attempt
      warn "  network error (#{e.class}): retrying in #{wait}s"
      sleep wait
      next
    end

    case resp.code.to_i
    when 200
      data = JSON.parse(resp.body)
      text_block = data["content"].find { |b| b["type"] == "text" }
      raise "no text block in response: #{resp.body[0, 300]}" unless text_block
      parsed = JSON.parse(text_block["text"])
      return(
        {
          parsed: parsed,
          cache_read: data.dig("usage", "cache_read_input_tokens") || 0,
          cache_write: data.dig("usage", "cache_creation_input_tokens") || 0,
          input_tokens: data.dig("usage", "input_tokens") || 0,
          output_tokens: data.dig("usage", "output_tokens") || 0,
          stop_reason: data["stop_reason"],
        }
      )
    when 401, 403
      # Auth error — same key will fail for every remaining topic. Bail out so
      # the operator fixes the key before wasting more time.
      raise AuthError, "HTTP #{resp.code}: #{resp.body[0, 300]}"
    when 429, 500, 502, 503, 529
      wait = 2**attempt
      warn "  HTTP #{resp.code}: retrying in #{wait}s"
      sleep wait
    else
      raise "API error HTTP #{resp.code}: #{resp.body[0, 500]}"
    end
  end
  raise "exhausted #{MAX_RETRIES} retries"
end

# ---------------------------------------------------------------------------
# Resume: read existing CSV, skip IDs already classified.
# ---------------------------------------------------------------------------

done_ids = Set.new
if File.exist?(OUT_PATH)
  CSV.foreach(OUT_PATH, headers: true) { |row| done_ids << row["id"].to_i if row["id"] }
  puts "Resume mode: #{done_ids.size} topics already classified, skipping them"
end

rows = File.readlines(IN_PATH, chomp: true).map { |l| JSON.parse(l) }
total = rows.size
remaining = rows.reject { |r| done_ids.include?(r["id"]) }
puts "Classifying #{remaining.size}/#{total} topics with #{MODEL} ..."

write_header = !File.exist?(OUT_PATH) || File.size(OUT_PATH).zero?

cumulative = { cache_read: 0, cache_write: 0, input: 0, output: 0 }
fail_count = 0

CSV.open(OUT_PATH, "a") do |csv|
  csv << %w[id title lang reply_count suggested confidence reasoning] if write_header

  remaining.each_with_index do |r, i|
    begin
      result =
        call_claude(
          title: r["title"],
          body: r["body"],
          lang: r["lang"],
          reply_count: r["reply_count"],
        )
      p = result[:parsed]
      csv << [
        r["id"],
        r["title"],
        r["lang"],
        r["reply_count"],
        p["suggested"],
        p["confidence"],
        p["reasoning"],
      ]
      csv.flush

      cumulative[:cache_read] += result[:cache_read]
      cumulative[:cache_write] += result[:cache_write]
      cumulative[:input] += result[:input_tokens]
      cumulative[:output] += result[:output_tokens]

      cache_hit_marker =
        result[:cache_read].positive? ? "H" : (result[:cache_write].positive? ? "W" : ".")
      puts format(
             "[%3d/%d] %s id=%-5d  %-25s  conf=%.2f  %s",
             i + 1,
             remaining.size,
             cache_hit_marker,
             r["id"],
             p["suggested"],
             p["confidence"],
             r["title"][0, 40],
           )
    rescue AuthError => e
      # Auth errors mean the API key is invalid/revoked. Every remaining topic
      # would fail with the same error; abort immediately rather than burn 5+ min
      # producing duplicate FAIL lines. Operator must fix the key and rerun.
      warn ""
      warn "FAIL  Authentication error from Anthropic API:"
      warn "        #{e.message}"
      warn ""
      warn "        Halted at topic #{i + 1}/#{remaining.size} (id=#{r["id"]})."
      warn "        Likely causes:"
      warn "          - ANTHROPIC_API_KEY env var is unset or set to a revoked key"
      warn "          - #{KEY_PATH} contains a stale key (env var takes precedence; check both)"
      warn "        Fix the key, re-export it, then re-run this script (resume mode auto-skips already-classified ids)."
      exit 2
    rescue StandardError => e
      fail_count += 1
      warn "  FAIL id=#{r["id"]}: #{e.class}: #{e.message}"
      sleep 2
    end
  end
end

puts ""
puts "Wrote #{OUT_PATH}"
puts "Failures: #{fail_count}"
puts "Tokens — cache_read: #{cumulative[:cache_read]}  cache_write: #{cumulative[:cache_write]}  " \
       "input(uncached): #{cumulative[:input]}  output: #{cumulative[:output]}"
if cumulative[:cache_read].positive?
  hit_rate =
    cumulative[:cache_read].to_f /
      (cumulative[:cache_read] + cumulative[:cache_write] + cumulative[:input])
  puts "Cache hit rate (input tokens): #{(hit_rate * 100).round(1)}%"
end

# Non-zero exit on any failure so the caller (or shell pipeline) does not treat a
# silently incomplete classification as success. Resume mode (re-running this
# script) will pick up only the still-missing ids, so the operator's recovery
# path is just to rerun until fail_count is 0.
if fail_count > 0
  warn ""
  warn "FAIL  #{fail_count} topic(s) could not be classified. Re-run this script — it resumes from #{OUT_PATH} and only retries the missing ids. Do NOT run script/classify_migrate.rb until this is clean (or pass --allow-partial there if intentional)."
  exit 1
end

puts "Done."
