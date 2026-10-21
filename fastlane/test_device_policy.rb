require_relative "device_policy"

def device(udid, name = "iPhone")
  {"udid" => udid, "name" => name}
end

add, over = DevicePolicy.to_register([device("aa"), device("BB")], ["AA"], 75)
raise "Registered devices are skipped case-insensitively" unless add.map { |d| d["udid"] } == ["BB"] && over.empty?

add, = DevicePolicy.to_register([device("cc"), device("CC "), device("")], [], 75)
raise "Duplicates and blank UDIDs are ignored" unless add.map { |d| d["udid"] } == ["cc"]

add, over = DevicePolicy.to_register([device("a"), device("b"), device("c")], %w[x y], 4)
raise "Cap counts every registered device" unless add.size == 2 && over.map { |d| d["udid"] } == ["c"]

add, over = DevicePolicy.to_register([device("a")], %w[x y z], 2)
raise "Already over the cap registers nothing" unless add.empty? && over.size == 1

raise "Default limit leaves spare slots" unless DevicePolicy::DEFAULT_LIMIT == 75
raise "Blank names get a stable label" unless DevicePolicy.device_name(device("00008110-abcdef", "")) == "Staging tester ABCDEF"
raise "Names fit Apple's limit" unless DevicePolicy.device_name(device("a", "x" * 80)).size == 50
puts "device policy ok"
