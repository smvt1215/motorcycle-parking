require_relative "release_policy"

Build = Struct.new(:version, :processing_state)
raise "Range boundaries" unless ReleasePolicy.range(100).to_a == (101..109).to_a
raise "All tracks are searched" unless ReleasePolicy.play_candidate([["internal", [103]], ["production", [95]], ["custom", [109, 111]]], 100) == 109
raise "Other commits excluded" unless ReleasePolicy.play_candidate([["production", [100, 110]]], 100).nil?
raise "Completed production rollout is preserved" unless ReleasePolicy.play_candidate([["production", [103]], ["internal", [109]]], 100) == 103
builds = [Build.new("103", "VALID"), Build.new("109", "PROCESSING"), Build.new("108", "FAILED"), Build.new("110", "VALID")]
raise "Only valid current builds reused" unless ReleasePolicy.valid_build(builds, 100).version == "103"
raise "Processing builds wait" unless ReleasePolicy.processing?(builds, 100)
raise "Invalid builds never reused" unless ReleasePolicy.valid_build([Build.new("109", "INVALID")], 100).nil?
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
puts "Release retry policy passed"
