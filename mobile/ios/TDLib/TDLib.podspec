Pod::Spec.new do |s|
  s.name             = 'TDLib'
  s.version          = '1.8.68'
  s.summary          = 'Telegram Database Library (JSON interface) for Sado.'
  s.homepage         = 'https://github.com/tdlib/td'
  s.license          = { :type => 'BSL-1.0' }
  s.author           = { 'TDLib' => 'https://core.telegram.org/tdlib' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  # Produced by mobile/tool/build_tdlib_ios.sh. Dart loads it with DynamicLibrary.open('tdjson.framework/tdjson').
  s.vendored_frameworks = 'tdjson.xcframework'
  s.libraries        = 'c++', 'z'
end
