# Which tester devices to register with Apple, kept pure for tests.
module DevicePolicy
  # Apple allows 100 iPhones per membership year and only removes devices at
  # renewal; the staging sync stops below that so the owner keeps spare slots.
  DEFAULT_LIMIT = 75

  def self.normalize(udid)
    udid.to_s.strip.upcase
  end

  # Firebase testers' devices not yet on the Apple account, capped so the
  # account (every registered iPhone, enabled or not) never exceeds `limit`.
  # Returns [devices to register, devices left over because of the cap].
  def self.to_register(tester_devices, registered_udids, limit)
    known = registered_udids.map { |udid| normalize(udid) }
    fresh = tester_devices.uniq { |device| normalize(device["udid"]) }
                          .reject { |device| normalize(device["udid"]).empty? || known.include?(normalize(device["udid"])) }
    room = [limit - known.uniq.size, 0].max
    [fresh.first(room), fresh.drop(room)]
  end

  # Apple device names allow at most 50 characters; keep the tester's label.
  def self.device_name(device)
    name = device["name"].to_s.strip
    name = "Staging tester #{normalize(device['udid'])[-6..]}" if name.empty?
    name[0, 50]
  end
end
