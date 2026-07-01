#
# Xend native vault — CocoaPods spec for the iOS side of the xend_sdk plugin.
# The Swift under Classes/ owns keys, storage, biometrics, and the Ed25519 signature.
#
Pod::Spec.new do |s|
  s.name             = 'xend'
  s.version          = '0.1.0'
  s.summary          = 'Xend — embedded, non-custodial payments. Native vault.'
  s.description      = 'On-device Ed25519 keygen, Keychain storage, and (Phase 2) biometric signing.'
  s.homepage         = 'https://github.com/xend/xend'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Xend' => 'dev@xend.ai' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0' # CryptoKit Curve25519 requires iOS 13+
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
