# The React Native package's iOS side: the TurboModule (ios/*.{h,mm,swift}) and the vendored
# native iOS SDK (ios/vendor/RevokeGPT, made by tools/mobile-vendor at pack time and checked hash
# for hash against sdks/ios) compile into this one pod, so it depends on no other RevokeGPT pod
# (plan R8). The SDK's privacy manifest ships in its own resource bundle.
require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# A package packed without `pnpm run pack:prepare` has no SDK sources: fail here, not at link time.
unless File.exist?(File.join(__dir__, 'ios', 'vendor', 'VENDOR.json'))
  raise "#{package['name']}: ios/vendor is missing; run `pnpm run pack:prepare` (tools/mobile-vendor) before packing"
end

Pod::Spec.new do |s|
  s.name             = 'RevokeGPTReactNative'
  s.version          = package['version']
  s.summary          = 'RevokeGPT bot protection for React Native apps.'
  s.description      = 'Wraps the native RevokeGPT iOS SDK: proof of work, App Attest and the challenge sheet.'
  s.homepage         = 'https://revokegpt.com'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'RevokeGPT' => 'hello@revokegpt.com' }
  s.source           = { :git => 'https://github.com/ZaeemSattar/revokegpt-react-native.git', :tag => "v#{s.version}" }
  s.platforms        = { :ios => min_ios_version_supported }
  s.source_files     = 'ios/*.{h,mm,swift}', 'ios/vendor/RevokeGPT/**/*.swift'
  s.private_header_files = 'ios/*.h'
  s.resource_bundles = { 'RevokeGPT_Privacy' => ['ios/vendor/RevokeGPT/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'CryptoKit', 'DeviceCheck', 'Security', 'UIKit', 'WebKit'
  # The vendored SDK is Swift 6 (sdks/ios/RevokeGPT.podspec).
  s.swift_versions   = ['6.0']

  install_modules_dependencies(s)
end
