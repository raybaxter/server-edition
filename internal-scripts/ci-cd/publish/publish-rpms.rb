#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../../lib/gcloud_storage_lock'
require_relative '../../../lib/build_all_packages_support'
require_relative '../../../lib/general_support'
require_relative '../../../lib/shell_scripting_support'
require_relative '../../../lib/publishing_support'
require 'fileutils'
require 'shellwords'
require 'tmpdir'

class PublishRpms
  include GeneralSupport
  include ShellScriptingSupport
  include PublishingSupport

  def main
    require_envvar 'PRODUCTION_REPO_BUCKET_NAME'
    require_envvar 'TESTING'
    require_envvar 'OVERWRITE_EXISTING'
    if testing?
      require_envvar 'CI_ARTIFACTS_BUCKET_NAME'
      require_envvar 'CI_ARTIFACTS_RUN_NUMBER'
    end
    optional_envvar 'DRY_RUN'
    optional_envvar 'REMOTE_REPO_URL'
    optional_envvar 'LATEST_PRODUCTION_REPO_VERSION'
    @package_paths = ARGV

    print_header 'Initializing'
    Support.load_config
    group_packages_by_distro_and_arch
    create_temp_dirs
    pull_utility_image_if_not_exists
    initialize_locking
    fetch_and_import_signing_key

    version = nil
    synchronize do
      version = @orig_version = get_latest_production_repo_version
      fetch_repo(version) if version != 0

      print_header 'Updating repository'
      import_packages
      regenerate_repo_metadata
      check_lock_health

      if !dry_run?
        print_header 'Uploading changes'
        save_repo(version + 1)
        create_version_note(version + 1)
        check_lock_health

        print_header 'Activating changes'
        declare_latest_version(version + 1)
        restart_web_servers if !testing?
      end
    end

    if !dry_run?
      print_header 'Success!'
      print_conclusion(version + 1)
    end
  end

private
  def testing?
    getenv_boolean('TESTING')
  end

  def dry_run?
    getenv_boolean('DRY_RUN')
  end

  def group_packages_by_distro_and_arch
    @packages_by_distro_and_arch = {}
    @package_paths.each do |path|
      distro, arch = infer_package_distro_and_arch(path)
      if distro
        archs = (@packages_by_distro_and_arch[distro] ||= {})
        paths = (archs[arch] ||= [])
        paths << path
      else
        all_supported_distros.each do |distro|
          archs = (@packages_by_distro_and_arch[distro] ||= {})
          paths = (archs[arch] ||= [])
          paths << path
        end
      end
    end

    log_notice "Grouped #{@package_paths.size} packages into #{@packages_by_distro_and_arch.size} distributions"
    @packages_by_distro_and_arch.each_pair do |distro, archs|
      archs.each_pair do |arch, paths|
        log_info "#{distro} #{arch}:"
        paths.sort.each do |path|
          log_info " - #{path}"
        end
      end
    end
  end

  def infer_package_distro_and_arch(path)
    stdout_output, stderr_output, status = run_command_capture_output(
      'rpm', '-qip', path,
      log_invocation: false,
      check_error: false
    )

    if !status.success?
      abort "Error inspecting #{path}: #{stderr_output.chomp}"
    end

    if stdout_output =~ /^Distribution: (.+)/
      distro = $1
    else
      distro = nil
    end

    if stdout_output !~ /^Architecture *: (.+)/
      abort "Error inspecting #{path}: could not infer architecture"
    end
    arch = $1

    [distro, arch]
  end

  def all_supported_distros
    Support.distributions.find_all{ |d| d[:package_format] == :RPM }.map{ |d| d[:name] }
  end

  def create_temp_dirs
    log_notice 'Creating temporary directories'
    @temp_dir = Dir.mktmpdir
    @signing_key_path = "#{@temp_dir}/key.gpg"
    @local_repo_path = "#{@temp_dir}/repo"
    Dir.mkdir(@local_repo_path)
  end

  def initialize_locking
    if !testing?
      @lock = GCloudStorageLock.new(url: lock_url)
    end
  end

  def fetch_and_import_signing_key
    log_notice 'Fetching and importing signing key'

    File.open(@signing_key_path, 'wb') do |f|
      f.write(fetch_signing_key)
    end

    @gpg_key_id = infer_gpg_key_id(@temp_dir, @signing_key_path)
    log_info "Signing key ID: #{@gpg_key_id}"

    import_gpg_key(@temp_dir, @signing_key_path)
  end

  def lock_url
    "gs://#{ENV['PRODUCTION_REPO_BUCKET_NAME']}/locks/yum"
  end

  def synchronize
    if testing?
      yield
    else
      @lock.synchronize do
        yield
      end
    end
  end

  def check_lock_health
    return if testing?
    abort 'ERROR: lock is unhealthy. Aborting operation' if !@lock.healthy?
  end

  def latest_version_note_url
    if testing?
      latest_testing_version_note_url
    else
      latest_production_version_note_url
    end
  end

  def latest_production_version_note_url
    "gs://#{ENV['PRODUCTION_REPO_BUCKET_NAME']}/versions/latest_version.txt"
  end

  def latest_testing_version_note_url
    "gs://#{ENV['CI_ARTIFACTS_BUCKET_NAME']}/#{ENV['CI_ARTIFACTS_RUN_NUMBER']}/yum-repo/versions/latest_version.txt"
  end

  def version_note_url(version)
    if testing? && version != @orig_version
      "gs://#{ENV['CI_ARTIFACTS_BUCKET_NAME']}/#{ENV['CI_ARTIFACTS_RUN_NUMBER']}/yum-repo/versions/singleton/version.txt"
    else
      "gs://#{ENV['PRODUCTION_REPO_BUCKET_NAME']}/versions/#{version}/version.txt"
    end
  end

  def remote_repo_url(version)
    value = ENV['REMOTE_REPO_URL']
    return value if value

    if testing? && version != @orig_version
      "gs://#{ENV['CI_ARTIFACTS_BUCKET_NAME']}/#{ENV['CI_ARTIFACTS_RUN_NUMBER']}/yum-repo/versions/singleton/public"
    else
      "gs://#{ENV['PRODUCTION_REPO_BUCKET_NAME']}/versions/#{version}/public"
    end
  end

  def remote_repo_public_url(version)
    remote_repo_url(version).sub(%r(^gs://), 'https://storage.googleapis.com/')
  end

  def fetch_repo(version)
    log_notice 'Fetching existing repository'

    run_command(
      'gsutil', '-m', 'rsync', '-r',
      remote_repo_url(version),
      @local_repo_path,
      log_invocation: true,
      check_error: true,
      passthru_output: true
    )
  end

  def import_packages
    @packages_by_distro_and_arch.each_pair do |distro, archs|
      archs.each_pair do |arch, package_paths|
        import_packages_for_distro_and_arch(distro, arch, package_paths)
      end

      real_arch_names = archs.keys - ['noarch', 'src']
      import_arch_independent_packages_into_arch_dependent_subdirs(distro, real_arch_names, 'noarch')
      import_arch_independent_packages_into_arch_dependent_subdirs(distro, real_arch_names, 'src')
    end
  end

  def import_packages_for_distro_and_arch(distro, arch, package_paths)
    log_notice "[#{distro}] Importing #{package_paths.size} packages for #{arch}"

    target_dir = "#{@local_repo_path}/#{distro}/#{arch}"
    FileUtils.mkdir_p(target_dir) if !File.exist?(target_dir)

    if !getenv_boolean('OVERWRITE_EXISTING')
      package_paths = filter_existing_packages(distro, arch, package_paths)
    end

    hardlink_or_copy_files(package_paths, target_dir, log_cp_invocation: false)
  end

  def import_arch_independent_packages_into_arch_dependent_subdirs(distro, real_arch_names, independent_arch_name)
    return if real_arch_names.empty?
    source_dir = "#{@local_repo_path}/#{distro}/#{independent_arch_name}"
    package_paths = Dir["#{source_dir}/*.rpm"]
    return if package_paths.empty?

    log_notice "[#{distro}] Linking packages for #{independent_arch_name} into all architectures"
    real_arch_names.each do |arch|
      target_dir = "#{@local_repo_path}/#{distro}/#{arch}"
      delete_files(glob: "#{target_dir}/*.#{independent_arch_name}.rpm")
      hardlink_or_copy_files(package_paths, target_dir, log_cp_invocation: false)
    end
  end

  def filter_existing_packages(distro, arch, package_paths)
    package_paths.find_all do |path|
      target_path = "#{@local_repo_path}/#{distro}/#{arch}/#{File.basename(path)}"
      if File.exist?(target_path)
        log_info "     SKIP #{path}: package already in repository"
        false
      else
        log_info "  INCLUDE #{path}"
        true
      end
    end
  end

  def regenerate_repo_metadata
    @packages_by_distro_and_arch.each_pair do |distro, archs|
      archs.each_key do |arch|
        log_notice "[#{distro}] Regenerating repository metadata for #{arch}"
        target_dir = "#{@local_repo_path}/#{distro}/#{arch}"
        invoke_createrepo(target_dir)
        sign_repo(target_dir)
      end
    end
  end

  def invoke_createrepo(dir)
    if File.exist?("#{dir}/repodata/repomd.xml")
      update_arg = ['--update']
    else
      update_arg = []
    end
    run_command(
      'docker', 'run', '--rm',
      '-v', "#{dir}:/input:delegated",
      '--user', "#{Process.uid}:#{Process.gid}",
      utility_image_name,
      'createrepo',
      *update_arg,
      '/input',
      log_invocation: true,
      check_error: true
    )
  end

  def sign_repo(path)
    run_command(
      'gpg', "--homedir=#{@temp_dir}", "--local-user=#{@gpg_key_id}",
      '--batch', '--yes', '--detach-sign', '--armor',
      "#{path}/repodata/repomd.xml",
      log_invocation: true,
      check_error: true
    )
  end

  def save_repo(version)
    log_notice "Saving repository (as version #{version})"

    if !testing? && version != 0
      log_info "Copying over version #{version - 1}"
      run_command(
        'gsutil', '-m',
        '-h', "Cache-Control:#{cache_control_policy}",
        'rsync', '-r', '-d',
        remote_repo_url(version - 1),
        remote_repo_url(version),
        log_invocation: true,
        check_error: true,
        passthru_output: true
      )

      log_info "Uploading version #{version}"
    end

    run_command(
      'gsutil', '-m',
      '-h', "Cache-Control:#{cache_control_policy}",
      'rsync', '-r', '-d',
      @local_repo_path,
      remote_repo_url(version),
      log_invocation: true,
      check_error: true,
      passthru_output: true
    )
  end

  def create_version_note(version)
    log_notice 'Creating version note'

    run_bash(
      sprintf(
        'gsutil -q ' \
        '-h Content-Type:text/plain ' \
        "-h Cache-Control:#{cache_control_policy} " \
        'cp - %s <<<%s',
        Shellwords.escape(version_note_url(version)),
        Shellwords.escape(version.to_s)
      ),
      log_invocation: true,
      check_error: true,
      pipefail: false
    )
  end

  def declare_latest_version(version)
    log_notice "Declaring that latest state/repository version is #{version}"

    run_bash(
      sprintf(
        'gsutil -q ' \
        '-h Content-Type:text/plain ' \
        '-h Cache-Control:no-store ' \
        'cp - %s <<<%s',
        Shellwords.escape(latest_version_note_url),
        Shellwords.escape(version.to_s)
      ),
      log_invocation: true,
      check_error: true,
      pipefail: false
    )
  end

  def print_conclusion(version)
    log_notice "The YUM repository is now live at: #{remote_repo_public_url(version)}"
  end
end

PublishRpms.new.main
