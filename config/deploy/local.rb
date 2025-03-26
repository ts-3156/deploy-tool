require 'dotenv/load'
require 'aws-sdk-ec2'
require 'aws-sdk-elasticloadbalancingv2'

# Running in parallel makes it impossible to rescue Interrupt
SSHKit.config.default_runner = :sequence

class SSHUtil
  def self.append_to_config(id, host, ip)
    text = <<~"TEXT"
      # #{Date.today} #{id}
      Host #{host}
        HostName     #{ip}
        IdentityFile #{ENV['SSH_KEY']}
        User         #{ENV['SSH_USER']}
    TEXT
    File.open(ENV['SSH_CONFIG'], 'a') { |f| f.puts(text) }
    ENV['SSH_CONFIG']
  end
end

class NameUtil
  LIST = %w(Brilliant Cheerful Courageous Delightful Energetic Friendly Graceful Optimistic Radiant Vibrant)

  def self.gen(prefix)
    "#{prefix}-#{Time.now.strftime('%m%d%H%M')}-#{LIST.sample}"
  end
end

class AZUtil
  def self.az_to_subnet(az)
    case az[-1]
    when 'b' then ENV['AWS_SUBNET_B']
    when 'c' then ENV['AWS_SUBNET_C']
    else raise("Invalid AZ name=#{az}")
    end
  end
end

class EC2Client
  def initialize
    @ec2 = Aws::EC2::Resource.new(region: ENV['AWS_REGION'])
    @logger = Logger.new(STDOUT, datetime_format = '%Y-%m-%dT%H:%M:%S', formatter: proc { |s, t, p, m|
      "[#{t}] #{s} -- #{m}\n"
    })
  end

  def launch(name, values)
    params = {
        min_count: 1,
        max_count: 1,
        launch_template: pick_launch_template(values),
        instance_market_options: pick_market_type(values),
        security_group_ids: [values['security-group']],
        subnet_id: values['subnet-id'],
        instance_type: values['instance-type'] # Optional
    }.compact

    instance = @ec2.create_instances(params).first
    id = instance.id
    wait_until(id, :instance_running)
    wait_until(id, :instance_status_ok)
    instance = retrieve(id)
    wait_until_ssh_connection_ok(id, instance.public_ip_address)
    instance.create_tags(tags: [{key: 'Name', value: name}])

    instance
  rescue Interrupt, StandardError => e
    if id
      @logger.error "\x1b[31mTerminate #{id} because #{e.class} is raised\x1b[0m"
      terminate(id)
    end
    raise
  end

  def terminate(id)
    @ec2.client.terminate_instances({instance_ids: [id]})
  end

  def retrieve(id)
    filters = [{name: 'instance-id', values: [id]}]
    @ec2.instances(filters: filters).first
  end

  private

  def pick_launch_template(values)
    {
        launch_template_id: values['launch-template-id'],
        version: values['launch-template-version'] # Optional
    }.compact
  end

  def pick_market_type(values)
    if values['market-type'] == 'spot'
      {market_type: 'spot'}
    end
  end

  def wait_until_ssh_connection_ok(id, ip, max_retries: 60, interval: 5)
    cmd = "ssh -q -i #{ENV['SSH_KEY']} -o StrictHostKeyChecking=no #{ENV['SSH_USER']}@#{ip} exit"

    max_retries.times do |n|
      @logger.info "waiting for ssh_connection_ok #{id}"
      system(cmd, exception: false) ? break : sleep(interval)
      raise 'ssh connection not established' if n == max_retries - 1
    end
  end

  def wait_until(id, state)
    @ec2.client.wait_until(state, instance_ids: [id]) do |w|
      w.before_wait do |n, resp|
        @logger.info "waiting for #{state} #{id}"
      end
    end
  rescue ::Aws::Waiters::Errors::WaiterFailed => e
    raise "Failed message=#{e.message}"
  end

end

class TargetGroupClient
  def initialize(arn)
    @arn = arn
    @elb = Aws::ElasticLoadBalancingV2::Client.new(region: ENV['AWS_REGION'])
    @logger = Logger.new(STDOUT, datetime_format = '%Y-%m-%dT%H:%M:%S', formatter: proc { |s, t, p, m|
      "[#{t}] #{s} -- #{m}\n"
    })
  end

  def register(instance_id)
    previous_count = registered_instances.size
    params = {target_group_arn: @arn, targets: [{id: instance_id}]}
    @elb.register_targets(params)
    wait_until(:target_in_service, params)
    @logger.info "Current targets count is #{registered_instances.size} (was #{previous_count})"
  end

  def deregister(instance_id, min_count: 2)
    if (previous_count = registered_instances.size) < min_count
      raise "Cannot deregister #{instance_id} because a number of instances is less than #{min_count}"
    end

    params = {target_group_arn: @arn, targets: [{id: instance_id}]}
    @elb.deregister_targets(params)
    wait_until(:target_deregistered, params)
    @logger.info "Current targets count is #{registered_instances.size} (was #{previous_count})"
    true
  end

  def registered_instances(state: 'healthy', instance_type: nil)
    descriptions = @elb.
        describe_target_health({target_group_arn: @arn}).
        target_health_descriptions.
        select { |d| d.target_health.state == state }

    instances = descriptions.map do |desc|
      EC2Client.new.retrieve(desc.target.id)
    end

    if instance_type
      instances.select! { |i| i.instance_type == instance_type }
    end

    instances
  end

  def deregistrable_instance
    registered_instances.select do |instance|
      !instance.describe_attribute(attribute: 'disableApiTermination').disable_api_termination.value
    end.sort_by(&:launch_time)[0]
  end

  def pick_availability_zone
    count = availability_zones.map { |name| [name, 0] }.to_h
    registered_instances.each { |i| count[i.placement.availability_zone] += 1 }
    count.sort_by { |_, v| v }[0][0]
  end

  private

  def availability_zones
    arn = @elb.describe_target_groups(target_group_arns: [@arn]).target_groups[0].load_balancer_arns[0]
    @elb.describe_load_balancers(load_balancer_arns: [arn]).load_balancers[0].availability_zones.map(&:zone_name).sort
  end

  def wait_until(state, params)
    instance_id = params[:targets][0][:id]

    @elb.wait_until(state, params) do |w|
      w.before_wait do |n, resp|
        @logger.info "waiting for #{state} #{instance_id}"
      end
    end
  rescue ::Aws::Waiters::Errors::WaiterFailed => e
    raise "Failed message=#{e.message}"
  end
end

namespace :ec2 do
  %i(launch terminate register deregister).each do |name|
    task(name) { on(:local) { execute('echo "Started" >/dev/null') } }
  end

  task :launch do
    # TODO Create a lock file

    ec2 = EC2Client.new
    tg = TargetGroupClient.new(ENV['AWS_TARGET_GROUP'])
    name = NameUtil.gen(ENV['APP_NAME'])
    instance = ec2.launch(name, {
        'subnet-id' => AZUtil.az_to_subnet(tg.pick_availability_zone),
        'security-group' => ENV['AWS_SECURITY_GROUP'],
        'launch-template-id' => ENV['AWS_LAUNCH_TEMPLATE'],
        'instance-type' => ENV['AWS_INSTANCE_TYPE']
    })
    on :local do
      execute("tail -n 5 #{SSHUtil.append_to_config(instance.id, name, instance.public_ip_address)}")
    end

    set(:instance_name, name)
    set(:instance_id, instance.id)
  end

  task :terminate do
    EC2Client.new.terminate(fetch(:instance_id) || ENV['INSTANCE_ID'])
  end

  task :install do
    on fetch(:instance_name) do
      execute('sudo yum install -y -q httpd')
      execute(%q(sudo sh -c "echo 'hello' >/var/www/html/index.html"))
      execute('sudo service httpd start')
    end
  end

  task :uninstall do
    on fetch(:instance_name) do
      execute('sudo service httpd stop')
    end
  end

  task :register do
    client = TargetGroupClient.new(ENV['AWS_TARGET_GROUP'])
    client.register(fetch(:instance_id) || ENV['INSTANCE_ID'])
  end

  task :deregister do
    client = TargetGroupClient.new(ENV['AWS_TARGET_GROUP'])
    instance_id = ENV['INSTANCE_ID'] || client.deregistrable_instance.id
    client.deregister(instance_id)
    set(:deregistered_id, instance_id)
  end

  %i(launch terminate register deregister).each do |name|
    task(name) { on(:local) { execute('echo "Finished" >/dev/null') } }
  end
end

# Clear predefined 'deploy' task
Rake::Task['deploy'].clear_actions

task :deploy do
  invoke 'ec2:launch'
  invoke 'ec2:install'
  invoke 'ec2:register'
  invoke 'ec2:deregister'
  instance = EC2Client.new.retrieve(fetch(:deregistered_id))
  set(:instance_id, instance.id)
  set(:instance_name, instance.tags.find { |t| t.key == 'Name' }.value)
  invoke 'ec2:uninstall'
  invoke 'ec2:terminate'
end
