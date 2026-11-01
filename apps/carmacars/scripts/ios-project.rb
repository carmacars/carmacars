# Adds what scripts/native-setup.mjs wrote to the Xcode project (macOS only, the xcodeproj gem that comes with
# CocoaPods on GitHub's macOS runners): the entitlements file on every build configuration of the App target, and
# GoogleService-Info.plist to the app's resources. Running it twice changes nothing the second time.
#
#   ruby scripts/ios-project.rb ios/App/App.xcodeproj
require 'xcodeproj'

path = ARGV[0] or abort 'usage: ruby scripts/ios-project.rb <App.xcodeproj>'
project = Xcodeproj::Project.open(path)
target = project.targets.find { |t| t.name == 'App' } or abort 'no App target'

target.build_configurations.each do |c|
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'App/App.entitlements'
  c.build_settings['TARGETED_DEVICE_FAMILY'] = '1'
end

plist = File.join(File.dirname(path), 'App', 'GoogleService-Info.plist')
if File.exist?(plist)
  group = project.main_group.find_subpath('App', false) || project.main_group
  ref = group.files.find { |f| f.path == 'GoogleService-Info.plist' } || group.new_reference('GoogleService-Info.plist')
  target.add_resources([ref]) unless target.resources_build_phase.files_references.include?(ref)
end

project.save
puts 'ios-project: entitlements on the App target, iPhone only' + (File.exist?(plist) ? ', GoogleService-Info.plist in the resources' : '')
