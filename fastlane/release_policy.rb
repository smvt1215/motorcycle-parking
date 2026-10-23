# Pure decisions are separated from store/network operations for retry tests.
module ReleasePolicy
  SUBMITTED_STATES = %w[
    WAITING_FOR_REVIEW IN_REVIEW PENDING_DEVELOPER_RELEASE
    PENDING_APPLE_RELEASE PROCESSING_FOR_APP_STORE READY_FOR_SALE
    PROCESSING_FOR_DISTRIBUTION READY_FOR_DISTRIBUTION PREORDER_READY_FOR_SALE
    ACCEPTED PENDING_CONTRACT REPLACED_WITH_NEW_VERSION
    DEVELOPER_REMOVED_FROM_SALE REMOVED_FROM_SALE
  ].freeze

  # Google Play API track names: closed testing is "alpha", open testing "beta".
  PLAY_TRACKS = {"beta" => "alpha", "rc" => "beta"}.freeze

  # External TestFlight states in which the build already reached (or is
  # waiting on review for) the public group; a rerun must not submit again.
  EXTERNAL_DISTRIBUTED_STATES = %w[
    WAITING_FOR_BETA_REVIEW IN_BETA_REVIEW BETA_APPROVED IN_BETA_TESTING
  ].freeze

  def self.play_track(channel)
    PLAY_TRACKS.fetch(channel) { raise ArgumentError, "No Play testing track for #{channel}" }
  end

  def self.testflight_distributed?(state)
    EXTERNAL_DISTRIBUTED_STATES.include?(state)
  end

  def self.range(base)
    ((base + 1)..(base + 9))
  end

  def self.published_play_codes(releases)
    # A deliberately halted rollout has already been published; preserve the
    # operator's pause. A draft has never been published and must be advanced.
    releases.select { |release| %w[inProgress completed halted].include?(release.status) }
            .flat_map { |release| Array(release.version_codes) }.map(&:to_i)
  end

  def self.play_candidate(tracks, base, released_codes: [])
    production = released_codes.map(&:to_i).select { |code| range(base).cover?(code) }
    return production.max unless production.empty?

    candidates = tracks.flat_map { |_, codes| codes }.map(&:to_i).select { |code| range(base).cover?(code) }
    candidates.max
  end

  # A store release promotes only what the RC actually shipped: a version
  # code already published on production, else one on the RC's open testing
  # track. A beta-only (closed testing) build is never promoted.
  def self.promotable_play_code(tracks, base, released_codes: [])
    production = released_codes.map(&:to_i).select { |code| range(base).cover?(code) }
    return production.max unless production.empty?

    rc_track = tracks.to_h.fetch(play_track("rc"), [])
    rc_track.map(&:to_i).select { |code| range(base).cover?(code) }.max
  end

  # The VALID build the RC sent to the public TestFlight group; a build that
  # never reached external testers is not a release candidate.
  def self.distributed_build(builds, base)
    distributed = builds.select { |build| testflight_distributed?(build.build_beta_detail&.external_build_state) }
    valid_build(distributed, base)
  end

  def self.valid_build(builds, base)
    builds.select { |build| range(base).cover?(build.version.to_i) && build.processing_state == "VALID" }
          .max_by { |build| build.version.to_i }
  end

  def self.processing?(builds, base)
    builds.any? { |build| range(base).cover?(build.version.to_i) && build.processing_state == "PROCESSING" }
  end

  def self.submitted?(state)
    SUBMITTED_STATES.include?(state)
  end
end
