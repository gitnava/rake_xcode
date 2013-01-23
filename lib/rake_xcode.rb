require "pathname"
require 'rake/dsl_definition'
require 'net/http'
require 'xmlsimple'
  
module RakeXcode
  include Rake::DSL

  class TestFlight
    attr_accessor :team_token, :api_token, :notes, :notify, :distribution_lists
  end

  class Xcode
    attr_accessor :workspace, :configuration, :target, :scheme, :arch, :sdk, :profile, :identity, :testflight, :build_dir, :build_number, :version, :marketing_version

    def scheme_dir
      "#@configuration-#@sdk"
    end

    def output_path
      root_dir + "/#@build_dir/#@workspace/Build/Products/#{scheme_dir}/"
    end

    def app_file
      "#@target.app"
    end
    
    def app_path
      output_path + app_file
    end

    def dsym_dir
      app_file + ".dSYM"
    end

    def dsym_path
      output_path + dsym_dir
    end

    def dsym_zip_file
      dsym_dir + ".zip"
    end

    def dsym_zip_path
      output_path + dsym_zip_file
    end

    def ipa_file
      "#{@target}-#{@version}.ipa"
    end

    def ipa_path
      output_path + "#{@target}-#{@version}.ipa"
    end

    def build(actions)
      roots = "#{root_dir}/#@build_dir/#@workspace/Build/Products"
      sh "xcodebuild -workspace '#@workspace.xcworkspace' -configuration '#@configuration' -scheme '#@scheme' #{actions.join(' ')} SYMROOT=#{roots} OBJROOT=#{roots}"
    end

    def package
      sh "xcrun -sdk #@sdk PackageApplication -v #{app_path} --sign '#@identity' --embed '#@profile' -o '#{ipa_path}'"
    end

    def add_testflight
      raise 'Requires configuration block with testflight parameter e,g, xc.add_testflight do |tf|' unless block_given?
      @testflight = TestFlight.new
      yield @testflight
    end

  end

  def root_dir
    @@root_dir ||= File.absolute_path "#{Pathname.new(Rake.application.rakefile).dirname}"
  end
  
  def jenkins_changelog(jenkins_host_port, exclude_user)
    log = "User release"
    if ENV['JOB_NAME'] && ENV['BUILD_NUMBER'] && ENV['JENKINS_URL']
      url = "#{ENV['JENKINS_URL']}job/#{ENV['JOB_NAME']}/#{ENV['BUILD_NUMBER']}/api/xml?wrapper=changes&xpath=//changeSet//item"
      puts "changelog from url #{url}"
      xml_data = Net::HTTP.get_response(URI.parse(url)).body  
      changeSet = XmlSimple.xml_in(xml_data)
      if items = changeSet['item']
        messages = []
        items.each do |item|
          unless item['author'][0]['fullName'][0] == exclude_user
            msg = item['msg'][0].to_s            
            messages += msg.gsub("'",'').split(/\n/).map { |line| line.strip.gsub(/^(-\s*|\*\s*)/,'').strip }.delete_if { |line| !line.size || line=~/signed-off-by/i }.map { |line| "* #{line}" }
          end
        end
        log = messages.join("\\n") if messages.count
      end
    end  
    log
  end

  def xcode
    raise 'Requires configuration block with xcode parameter e.g. xcode do |xc|' unless block_given?
    @xcode = Xcode.new
    yield @xcode
    
    desc "Downloads ruby gem build dependencies from Bundler Gemfile"
    Rake::Task.define_task 'bundle' do
      sh "chmod a+w Gemfile.lock"
      sh "bundle update"
    end    

    desc "Downloads and constructs Cocoapods dependency project"
    Rake::Task.define_task 'pods' => ['bundle'] do
      sh "chmod a+w #{@xcode.workspace}.xcworkspace/contents.xcworkspacedata"
      sh "chmod -R a+w Pods" if File.exist? 'Pods'
      sh "chmod a+w Podfile.lock"
      sh "pod update"
    end

    desc "Clean build output for #{@xcode.scheme_dir}"
    task 'clean' do
      @xcode.build(['clean'])
      sh "rm -rf #{@xcode.output_path}"
    end

    desc "Run xcodebuild for #{@xcode.scheme_dir}"
    task 'build' => ['pods'] do
      sh "find . -name '*-Info.plist' -exec chmod a+w {} \\;"
      sh "find . -name 'project.pbxproj' -exec chmod a+w {} \\;"  
      sh "security unlock-keychain -p #{ENV['XKEYPASS']} ~/Library/Keychains/login.keychain" if ENV['XKEYPASS']
      sh "xcrun agvtool new-marketing-version #{@xcode.build_number ? @xcode.build_number : @xcode.version}"
      sh "xcrun agvtool new-version -all #{@xcode.marketing_version ? @xcode.marketing_version : @xcode.version}"
      @xcode.build(['build'])
    end

    desc "Package app as an IPA file for #{@xcode.scheme_dir}"
    Rake::Task.define_task 'package:ipa' =>['build'] do
      @xcode.package()
    end

    desc "Build frankied app bundle"
    task 'frank:build' => ['pods'] do
      sh "frank build --workspace='#{@xcode.workspace}.xcworkspace' --scheme='#{@xcode.scheme}' --arch=i386"
    end

    if @xcode.testflight
      desc 'Uploads ipa and zipped dsym files to TestFlight'
      task 'upload:testflight' do
        raise 'Missing IPA file, run package:ipa first!' if !File.exists? @xcode.ipa_path
        File.delete @xcode.dsym_zip_path if File.exists? @xcode.dsym_zip_path
        chdir @xcode.output_path do
          sh "zip -r #{@xcode.dsym_zip_file} #{@xcode.dsym_dir}"
        end
        command = "curl 'http://testflightapp.com/api/builds.json' -i "
        command << "-F file=@#{@xcode.ipa_path} "
        command << "-F dsym=@#{@xcode.dsym_zip_path} "
        command << "-F api_token='#{@xcode.testflight.api_token}' "
        command << "-F team_token='#{@xcode.testflight.team_token}' "
        command << "-F notes='#{@xcode.testflight.notes}' "
        command << "-F notify='#{!@xcode.testflight.notify}' "
        command <<  "-F distribution_lists='#{@xcode.testflight.distribution_lists.join(', ')}'" unless @xcode.testflight.distribution_lists.empty?
#        puts "empty #{@xcode.testflight.distribution_lists.empty?} command #{command}"
        sh command
      end
    end

    @xcode
  end

end
