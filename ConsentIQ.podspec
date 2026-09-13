Pod::Spec.new do |s|
  s.name             = 'ConsentIQ'
  s.version          = '1.0.0'
  s.summary          = 'ConsentIQ consent management SDK for iOS.'
  s.description      = <<-DESC
    Fetches a ConsentIQ property's configuration, shows a consent sheet on first launch,
    records the visitor's choices against a pseudonymous subject id, and lets the app gate
    features on consent. SwiftUI and UIKit.
  DESC
  s.homepage         = 'https://github.com/iqworksai/consentiq-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = 'IQWorks'
  s.source           = { :git => 'https://github.com/iqworksai/consentiq-ios.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '16.0'
  s.swift_versions   = ['5.9']
  s.source_files     = 'Sources/ConsentIQ/**/*.swift'
  s.frameworks       = 'Foundation', 'SwiftUI', 'UIKit', 'Combine'
end
