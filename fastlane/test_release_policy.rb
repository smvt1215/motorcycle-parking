require_relative "release_policy"

Build = Struct.new(:version, :processing_state)
PlayRelease = Struct.new(:status, :version_codes)
ALL = ReleasePolicy.range(101, 109)
BETA = ReleasePolicy.range(101, 104)
RC = ReleasePolicy.range(105, 109)
raise "Range boundaries" unless ALL.to_a == (101..109).to_a
raise "Range accepts gate output strings" unless ReleasePolicy.range("105", "109") == RC
raise "All tracks are searched" unless ReleasePolicy.play_candidate([["internal", [103]], ["production", [95]], ["custom", [109, 111]]], ALL) == 109
raise "Other commits excluded" unless ReleasePolicy.play_candidate([["production", [100, 110]]], ALL).nil?
raise "Completed production rollout is preserved" unless ReleasePolicy.play_candidate([["production", [103]], ["internal", [109]]], ALL, released_codes: [103]) == 103
draft = PlayRelease.new("draft", ["109"])
active = PlayRelease.new("inProgress", ["103"])
completed = PlayRelease.new("completed", ["104"])
halted = PlayRelease.new("halted", ["105"])
raise "Draft is not a completed rollout" unless ReleasePolicy.published_play_codes([draft]).empty?
raise "Published states retained" unless ReleasePolicy.published_play_codes([active, completed, halted, draft]) == [103, 104, 105]
raise "Only completed testing releases reached every tester" unless ReleasePolicy.completed_play_codes([active, completed, halted, draft]) == [104]
raise "Draft is reused for promotion rather than uploaded again" unless ReleasePolicy.play_candidate([["production", [109]]], ALL, released_codes: []) == 109
raise "Published build takes precedence over newer draft" unless ReleasePolicy.play_candidate([["production", [103, 109]]], ALL, released_codes: [103]) == 103
builds = [Build.new("103", "VALID"), Build.new("109", "PROCESSING"), Build.new("108", "FAILED"), Build.new("110", "VALID")]
raise "Only valid current builds reused" unless ReleasePolicy.valid_build(builds, ALL).version == "103"
raise "Processing builds wait" unless ReleasePolicy.processing?(builds, ALL)
raise "Invalid builds never reused" unless ReleasePolicy.valid_build([Build.new("109", "INVALID")], ALL).nil?
%w[
  WAITING_FOR_REVIEW IN_REVIEW READY_FOR_DISTRIBUTION PENDING_DEVELOPER_RELEASE
  PROCESSING_FOR_DISTRIBUTION PROCESSING_FOR_APP_STORE ACCEPTED PENDING_CONTRACT
  REPLACED_WITH_NEW_VERSION DEVELOPER_REMOVED_FROM_SALE REMOVED_FROM_SALE
].each do |state|
  raise "Completed submission #{state}" unless ReleasePolicy.submitted?(state)
end
%w[PREPARE_FOR_SUBMISSION READY_FOR_REVIEW REJECTED DEVELOPER_REJECTED WAITING_FOR_EXPORT_COMPLIANCE].each do |state|
  raise "Submission still required #{state}" if ReleasePolicy.submitted?(state)
end
raise "Beta goes to closed testing" unless ReleasePolicy.play_track("beta") == "alpha"
raise "RC goes to open testing" unless ReleasePolicy.play_track("rc") == "beta"
begin
  ReleasePolicy.play_track("release")
  raise "Store release has no testing track"
rescue ArgumentError
end
%w[WAITING_FOR_BETA_REVIEW IN_BETA_REVIEW BETA_APPROVED IN_BETA_TESTING].each do |state|
  raise "External distribution done #{state}" unless ReleasePolicy.testflight_distributed?(state)
end
[nil, "READY_FOR_BETA_SUBMISSION", "BETA_REJECTED", "MISSING_EXPORT_COMPLIANCE", "EXPIRED"].each do |state|
  raise "External distribution still required #{state.inspect}" if ReleasePolicy.testflight_distributed?(state)
end
raise "Production release kept" unless ReleasePolicy.promotable_play_code([["beta", [109]]], ALL, released_codes: [103]) == 103
raise "RC open-testing build promoted" unless ReleasePolicy.promotable_play_code([["alpha", [108]], ["beta", [105]]], ALL) == 105
raise "Beta-only build never promoted" unless ReleasePolicy.promotable_play_code([["alpha", [108]], ["internal", [109]]], ALL).nil?
raise "Other commits on the RC track ignored" unless ReleasePolicy.promotable_play_code([["beta", [95, 110]]], ALL).nil?
BetaDetail = Struct.new(:external_build_state)
TestBuild = Struct.new(:version, :processing_state, :build_beta_detail)
shipped = TestBuild.new("104", "VALID", BetaDetail.new("IN_BETA_TESTING"))
unshipped = TestBuild.new("106", "VALID", BetaDetail.new("READY_FOR_BETA_SUBMISSION"))
no_detail = TestBuild.new("107", "VALID", nil)
raise "Distributed RC build chosen" unless ReleasePolicy.distributed_build([shipped, unshipped, no_detail], ALL).version == "104"
raise "Undistributed build never submitted" unless ReleasePolicy.distributed_build([unshipped, no_detail], ALL).nil?
%w[WAITING_FOR_BETA_REVIEW IN_BETA_REVIEW BETA_APPROVED].each do |state|
  pending = TestBuild.new("108", "VALID", BetaDetail.new(state))
  raise "Build still in Beta App Review is never promoted (#{state})" unless ReleasePolicy.distributed_build([pending], ALL).nil?
  raise "Review state still deduplicates reruns (#{state})" unless ReleasePolicy.testflight_distributed?(state)
end
raise "Only installable state is available" unless ReleasePolicy.testflight_available?("IN_BETA_TESTING") && !ReleasePolicy.testflight_available?("WAITING_FOR_BETA_REVIEW")
# A beta binary (staging backend) is never reused, promoted or submitted as an RC.
beta_build = TestBuild.new("102", "VALID", BetaDetail.new("IN_BETA_TESTING"))
raise "RC never sees beta builds" unless ReleasePolicy.valid_build([beta_build], RC).nil?
raise "RC never submits beta builds" unless ReleasePolicy.distributed_build([beta_build], RC).nil?
raise "RC never promotes beta codes" unless ReleasePolicy.play_candidate([["alpha", [102]]], RC).nil?
raise "RC finds its own build" unless ReleasePolicy.valid_build([beta_build, TestBuild.new("106", "VALID", nil)], RC).version == "106"
raise "Beta never reuses RC builds" unless ReleasePolicy.play_candidate([["beta", [106]]], BETA).nil?
puts "Release retry policy passed"
