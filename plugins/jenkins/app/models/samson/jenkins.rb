# frozen_string_literal: true
require 'jenkins_api_client'

module Samson
  class Jenkins
    URL = ENV['JENKINS_URL']
    USERNAME = ENV['JENKINS_USERNAME']
    API_KEY = ENV['JENKINS_API_KEY']
    ERROR_COLUMN_LIMIT = 255
    JENKINS_BUILD_PARAMETRS_PREFIX = "SAMSON_"
    JENKINS_BUILD_PARAMETERS_DEFAULT_VALUE = ""
    JENKINS_DESC_HEADER = "#### SAMSON DESCRIPTION STARTS ####"
    JENKINS_DESC_FOOTER = "#### SAMSON DESCRIPTION ENDS ####"
    JOB_NAME_PREFIX = '*'
    JENKINS_JOB_CACHE_TIME = 1.day
    JENKINS_JOB_DESC =
      "Following text is generated by Samson. Please do not edit manually.\n"\
      "This job is triggered from following Samson projects and stages:\n"\
      "%{job_names}\n"\
      "Build Parameters starting with #{JENKINS_BUILD_PARAMETRS_PREFIX} are updated "\
      "automatically by Samson. Please disable automatic updating "\
      "of this jenkins job from the above mentioned samson projects "\
      "before manually editing build parameters or description."
    JENKINS_BUILD_PARAMETERS = {
      buildStartedBy: "Samson username of the person who started the deployment.",
      originatedFrom: "Samson project + stage + commit hash from github tag",
      commit: "Github commit hash of the change deployed.",
      tag: "Github tags of the commit being deployed.",
      deployUrl: "Samson url which triggered the current job.",
      emails: "Emails of the committers, buddy and user for current deployment."\
                " Please see samson to exclude the committers email."
    }.freeze
    attr_reader :job_name, :deploy

    def self.deployed!(deploy)
      return unless deploy.succeeded?
      deploy.stage.jenkins_job_names.to_s.strip.split(/, ?/).map do |job_name|
        job_id = new(job_name, deploy).build
        attributes = {name: job_name, deploy_id: deploy.id}
        if job_id.is_a?(Integer)
          attributes[:jenkins_job_id] = job_id
        else
          attributes[:status] = "STARTUP_ERROR"
          attributes[:error] = job_id.to_s.slice(0, ERROR_COLUMN_LIMIT)
        end
        JenkinsJob.create!(attributes)
      end
    end

    def initialize(job_name, deploy)
      @job_name = job_name
      @deploy = deploy
    end

    def jenkins_job_cache_key
      job_name + "_conf"
    end

    def jenkins_job_config
      conf = Rails.cache.fetch(
        jenkins_job_cache_key,
        expires_in: JENKINS_JOB_CACHE_TIME,
        race_condition_ttl: 5.minute
      ) do
        client.job.get_config(job_name)
      end
      Nokogiri::XML(conf)
    end

    # we need to add new build parameters without manually changing each job's configuration in
    # manually. To do this, we check if this job is mentioned in
    # description of jenkins job. if not, we add it. We use JENKINS_DESC_HEADER/FOOTER markers
    # to keep track of description added through samson.
    def check_job_config
      conf = jenkins_job_config
      changes = {}
      expected_build_parameters = JENKINS_BUILD_PARAMETERS.keys
      present_build_params = build_params(conf).map(&:to_sym)
      missing_build_params = expected_build_parameters.to_set - present_build_params.to_set
      if missing_build_params.any?
        changes["build_params"] = missing_build_params
      end
      unless description_exists?(conf)
        changes['job_description'] = true
      end
      changes
    end

    def build_job_config(changes)
      Rails.cache.delete(jenkins_job_cache_key)
      conf = jenkins_job_config
      if changes.key?('build_params')
        add_build_parameters(conf, changes['build_params'])
      end
      unless description_exists?(conf)
        add_job_description(conf)
      end
      conf
    end

    def build_params(conf)
      params = conf.xpath("//hudson.model.StringParameterDefinition")
      params_array = []
      params.each do |param|
        param.children.each do |value|
          if value.name == "name"
            if val = value.content.split(JENKINS_BUILD_PARAMETRS_PREFIX, 2)[1]
              params_array << val
            end
          end
        end
      end
      params_array
    end

    def description(conf)
      conf.xpath("//description").first
    end

    def jenkins_desc_job_name
      "#{JOB_NAME_PREFIX} #{deploy.project.name} - #{deploy.stage.name}"
    end

    def extract_description(conf)
      desc = description(conf)
      content = desc.content.split("\n").map(&:squish)
      desc_start_index = content.index(JENKINS_DESC_HEADER)
      desc_end_index = content.index(JENKINS_DESC_FOOTER)
      if desc_start_index && desc_end_index
        job_names = content[desc_start_index..desc_end_index].select { |c| c.starts_with?(JOB_NAME_PREFIX) }
        prev_content = content[0, desc_start_index] + content[(desc_end_index + 1), content.size]
      else
        job_names = []
        prev_content = content
      end
      [prev_content, job_names]
    end

    def add_job_description(conf)
      prev_content, job_names = extract_description(conf)
      # add present job name if not included
      unless job_names.include?(jenkins_desc_job_name)
        job_names.append(jenkins_desc_job_name)
      end

      # update desc
      desc = description(conf)
      desc.content = [
        *prev_content,
        JENKINS_DESC_HEADER,
        JENKINS_JOB_DESC % {job_names: job_names.join("\n")},
        JENKINS_DESC_FOOTER
      ].join("\n")
    end

    def description_exists?(conf)
      desc = description(conf).content
      head = desc.index(JENKINS_DESC_HEADER)
      foot = desc.index(JENKINS_DESC_FOOTER)
      job = desc.index(jenkins_desc_job_name)
      head && foot && job && head < job && job < foot
    end

    def find_or_add_parameter_definition(conf)
      name = "//parameterDefinitions"
      conf.xpath(name).first || begin
        conf.xpath("//properties").first.add_child(
          '<hudson.model.ParametersDefinitionProperty>'\
          '<parameterDefinitions />'\
          '</hudson.model.ParametersDefinitionProperty>'
        )
        conf.xpath(name).first
      end
    end

    def add_build_parameters(conf, missing_parameters)
      properties_element = find_or_add_parameter_definition(conf)
      missing_parameters.each do |name|
        properties_element.add_child(
          {
            name: JENKINS_BUILD_PARAMETRS_PREFIX + name.to_s,
            description: JENKINS_BUILD_PARAMETERS.fetch(name),
            defaultValue: JENKINS_BUILD_PARAMETERS_DEFAULT_VALUE
          }.to_xml(skip_instruct: true, root: 'hudson.model.StringParameterDefinition')
        )
      end
    end

    def post_job_config(conf)
      client.job.post_config(job_name, conf.to_xml.to_s)
      Rails.cache.delete(jenkins_job_cache_key)
    end

    def build
      opts = {'build_start_timeout' => 60}
      originated_from = deploy.project.name + '_' + deploy.stage.name + '_' + deploy.reference
      build_params = {
        buildStartedBy: deploy.user.name,
        originatedFrom: originated_from,
        commit: deploy.job.commit,
        tag: deploy.job.tag,
        deployUrl: deploy.url,
        emails: notify_emails
      }
      if deploy.stage.jenkins_build_params
        changes = check_job_config
        if changes.any?
          new_config = build_job_config(changes)
          post_job_config(new_config)
        end
        build_params = build_params.map { |k, v| [JENKINS_BUILD_PARAMETRS_PREFIX + k.to_s, v] }.to_h
      end
      client.job.build(job_name, build_params, opts).to_i
    rescue Timeout::Error => e
      "Jenkins '#{job_name}' build failed to start in a timely manner.  #{e.class} #{e}"
    rescue JenkinsApi::Exceptions::ApiException => e
      "Problem while waiting for '#{job_name}' to start.  #{e.class} #{e}"
    end

    def job_status(jenkins_job_id)
      response(jenkins_job_id)['result']
    end

    def job_url(jenkins_job_id)
      response(jenkins_job_id)['url']
    end

    private

    def response(jenkins_job_id)
      @response ||=
        begin
          client.job.get_build_details(job_name, jenkins_job_id)
        rescue JenkinsApi::Exceptions::NotFound => e
          {'result' => e.message, 'url' => '#'}
        end
    end

    def client
      @@client ||= JenkinsApi::Client.new(server_url: URL, username: USERNAME, password: API_KEY).tap do |cli|
        cli.logger = Rails.logger
      end
    end

    def notify_emails
      emails = [deploy.user.email]
      if deploy.buddy
        emails.push(deploy.buddy.email)
      end
      if deploy.stage.jenkins_email_committers
        emails.concat(deploy.changeset.commits.map(&:author_email))
      end

      emails.compact!
      emails.select! { |e| e.include?('@') }
      emails.map! { |x| Mail::Address.new(x) }
      if restricted_domain = ENV["EMAIL_DOMAIN"]
        emails.select! { |x| x.domain.casecmp(restricted_domain) == 0 }
      end
      emails.map(&:address).uniq.join(",")
    end
  end
end
