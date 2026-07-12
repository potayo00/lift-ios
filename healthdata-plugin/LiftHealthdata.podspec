Pod::Spec.new do |s|
  s.name = 'LiftHealthdata'
  s.version = '1.0.0'
  s.summary = 'HealthKit bridge for Lift'
  s.license = { :type => 'MIT' }
  s.homepage = 'https://github.com/local/lift-healthdata'
  s.author = 'Lift'
  s.source = { :git => 'https://github.com/local/lift-healthdata.git', :tag => s.version.to_s }
  s.source_files = 'ios/Plugin/**/*.{swift,h,m}'
  s.ios.deployment_target = '14.0'
  s.dependency 'Capacitor'
  s.frameworks = 'HealthKit'
  s.swift_version = '5.1'
end
