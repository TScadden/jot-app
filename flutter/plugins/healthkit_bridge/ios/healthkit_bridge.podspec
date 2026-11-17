#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint healthkit_bridge.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'healthkit_bridge'
  s.version          = '0.0.1'
  s.summary          = 'Tabs HealthKit bridge (iOS).'
  s.description      = <<-DESC
Local iOS-only Flutter plugin serving the Tabs health MethodChannel
bridge from HealthKit, on the same channel the Android
health_connect_bridge plugin serves from Health Connect.
                       DESC
  s.homepage         = 'https://github.com/TScadden/jot-app'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Tabs Studio' => 'contacttabsapp@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'healthkit_bridge/Sources/healthkit_bridge/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any required
  # reason APIs, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information, see
  # https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'healthkit_bridge_privacy' => ['healthkit_bridge/Sources/healthkit_bridge/PrivacyInfo.xcprivacy']}
end
