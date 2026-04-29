# Diagnostic: verify Community Space lock effectiveness for a specific user.
#
# Usage (as discourse user, RAILS_ENV=production):
#   bin/rails runner check_lock.rb <username>
#
# Tells you 3 things:
#   1. The user's permission profile (admin / moderator / trust level)
#   2. Whether Discourse's Guardian thinks they can create a topic in Community Space
#   3. The category_groups rows in DB for Community Space (the actual lock state)
#
# If user is non-admin, non-mod, low trust level, AND can_create_topic = false,
# AND category_groups shows everyone -> create_post (permission_type=2),
# the lock is fully working. Any "+ New Topic" the user sees in browser is
# frontend cache (hard refresh fixes).

identifier = ARGV[0]
abort "Usage: bin/rails runner check_lock.rb <username_or_email>" if identifier.nil? || identifier.empty?

# Accept either username or email
u = User.find_by(username: identifier)
unless u
  ue = UserEmail.find_by(email: identifier.downcase)
  u = ue&.user
end
abort "User not found by username or email: '#{identifier}'" unless u

cs = Category.find_by(name: "Community Space", parent_category_id: nil)
abort "Community Space category not found" unless cs

g = Guardian.new(u)

puts "=== User profile ==="
puts "  username:     #{u.username}"
puts "  id:           #{u.id}"
puts "  admin:        #{u.admin}"
puts "  moderator:    #{u.moderator}"
puts "  trust_level:  #{u.trust_level}"
puts "  groups:       #{u.groups.map(&:name).join(", ")}"

# Check parent + all subcategories
all_categories = [cs] + Category.where(parent_category_id: cs.id).order(:id).to_a

all_categories.each do |cat|
  label = cat.id == cs.id ? "Community Space (top-level)" : "Community Space > #{cat.name}"

  puts ""
  puts "=== #{label}  (id=#{cat.id}) ==="
  puts "  can_see_category?            = #{g.can_see_category?(cat)}"
  puts "  can_create_topic_on_category? = #{g.can_create_topic_on_category?(cat)}"

  rows = CategoryGroup.where(category_id: cat.id)
  if rows.empty?
    puts "  category_groups: (no rows — category should be fully open)"
  else
    rows.each do |cg|
      group_name = Group.find_by(id: cg.group_id)&.name
      type_name =
        case cg.permission_type
        when 1
          "full (see + reply + new topic)"
        when 2
          "create_post (see + reply, NO new topic)"
        when 3
          "readonly (see only)"
        else
          "unknown(#{cg.permission_type})"
        end
      puts "  category_groups: group_id=#{cg.group_id} (#{group_name})  permission_type=#{cg.permission_type}  -> #{type_name}"
    end
  end
end

puts ""
puts "=== Conclusion ==="
expected_locked =
  CategoryGroup.where(
    category_id: cs.id,
    group_id: 0,
    permission_type: 2,
  ).exists?

subcats = Category.where(parent_category_id: cs.id).order(:id).to_a
subcat_create_results = subcats.map { |sc| [sc.name, g.can_create_topic_on_category?(sc)] }
subcat_blocked = subcat_create_results.reject { |_, can| can }

if !expected_locked
  puts "  WARNING: 'everyone -> create_post' row missing on Community Space top-level. Lock NOT applied."
elsif u.admin || u.moderator
  puts "  This user (#{u.username}) is admin/moderator — they bypass category permissions"
  puts "  and will always see '+ New Topic'. Use a non-admin user to verify the lock."
elsif g.can_create_topic_on_category?(cs)
  puts "  WARNING: Lock is in DB but Guardian still allows topic creation on parent. Investigate."
elsif subcat_blocked.any?
  puts "  Top-level locked correctly, but subcategories ALSO blocked for this user:"
  subcat_blocked.each { |name, _| puts "    - #{name}" }
  puts ""
  puts "  This is Discourse's permission inheritance — when a parent has restricted"
  puts "  permission_type, subcategories with no explicit category_groups can't grant"
  puts "  MORE permission than the parent. To allow posting in subcategories, each"
  puts "  subcategory needs its OWN category_groups row granting full (permission_type=1)."
else
  puts "  OK: Top-level locked, subcategories accept posts. Frontend cache if button still shows on top-level."
end
