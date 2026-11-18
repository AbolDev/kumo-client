# Adds the tunnel extension (ios/KumoTunnel) to the Xcode project of the app, and the entitlements, the bundle ids and the
# framework of sing-box (ios/Libbox/Libbox.xcframework) it needs. Run once on a Mac with the gem `xcodeproj` (CocoaPods brings it):
#
#   ruby tools/ios_add_tunnel.rb
#
# It can be run again: it stops when the target is already there. The bundle ids: the app is app.kumo.vpn, the extension
# app.kumo.vpn.tunnel, and both are in the App Group group.app.kumo.vpn (made in the developer account, see docs/ios).
require 'xcodeproj'

APP_ID = 'app.kumo.vpn'.freeze
TUNNEL_ID = "#{APP_ID}.tunnel".freeze
DEPLOYMENT = '15.5'.freeze

project_path = File.expand_path('../ios/Runner.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

if project.targets.any? { |t| t.name == 'KumoTunnel' }
  puts 'KumoTunnel is already in the project'
  exit 0
end

runner = project.targets.find { |t| t.name == 'Runner' } or abort('no Runner target')

# ---- the app: its id and its entitlements, and the files of the VPN
runner.build_configurations.each do |c|
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = APP_ID
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT
end
runner_group = project.main_group['Runner']
runner_group.new_file('Runner.entitlements') unless runner_group.files.any? { |f| f.path == 'Runner.entitlements' }
vpn_ref = runner_group.files.find { |f| f.path == 'KumoVpn.swift' } || runner_group.new_file('KumoVpn.swift')
runner.add_file_references([vpn_ref]) unless runner.source_build_phase.files_references.include?(vpn_ref)
runner.add_system_framework('NetworkExtension')

# ---- the extension
ext = project.new_target(:app_extension, 'KumoTunnel', :ios, DEPLOYMENT)
group = project.main_group.new_group('KumoTunnel', 'KumoTunnel')
sources = %w[PacketTunnelProvider.swift KumoPlatformInterface.swift].map { |f| group.new_file(f) }
group.new_file('Info.plist')
group.new_file('KumoTunnel.entitlements')
ext.add_file_references(sources)
ext.add_system_framework('NetworkExtension')

ext.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = TUNNEL_ID
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['INFOPLIST_FILE'] = 'KumoTunnel/Info.plist'
  s['CODE_SIGN_ENTITLEMENTS'] = 'KumoTunnel/KumoTunnel.entitlements'
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['SKIP_INSTALL'] = 'YES'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  s['CLANG_ENABLE_MODULES'] = 'YES'
  # sing-box is a Go program: its static library needs the resolver library of the system.
  s['OTHER_LDFLAGS'] = '$(inherited) -lresolv'
end

# The framework of sing-box (built by .github/workflows/ios-test.yml, put in ios/Libbox; it is not in the repository).
libbox_group = project.main_group.new_group('Libbox', 'Libbox')
libbox = libbox_group.new_file('Libbox.xcframework')
ext.frameworks_build_phase.add_file_reference(libbox, true)

# ---- put the extension in the app (a phase before the script that thins the binary, or Xcode finds a cycle)
embed = runner.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
build_file = embed.add_file_reference(ext.product_reference, true)
build_file.settings = { 'ATTRIBUTES' => %w[RemoveHeadersOnCopy] }
thin = runner.build_phases.find { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
if thin
  runner.build_phases.move(embed, runner.build_phases.index(thin))
end
runner.add_dependency(ext)

project.save
puts "Added KumoTunnel (#{TUNNEL_ID}) to #{project_path}"
