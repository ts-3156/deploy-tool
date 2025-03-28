#!/usr/bin/env ruby

require 'json'

class App
  REGION = '__REGION__'

  def instance_token
    @instance_token ||= `curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 3600"`
  end

  def instance_id
    @instance_id ||= `curl -s -H "X-aws-ec2-metadata-token: #{instance_token}" http://169.254.169.254/latest/meta-data/instance-id`.chomp
  end

  def instance_name
    @instance_name ||= `aws ec2 describe-tags --filters "Name=resource-id,Values=#{instance_id}" "Name=key,Values=Name" --region #{REGION} --query="Tags[0].Value"`.gsub(/["\n]/, '')
  end

  def marked_to_be_terminated?
    resp = `curl -s -H "X-aws-ec2-metadata-token: #{instance_token}" http://169.254.169.254/latest/meta-data/spot/instance-action`
    !resp.include?('Not Found')
  end

  def running?
    `sudo service httpd status`.include?('running')
  end

  def stop
    `sudo service httpd stop`
  end

  def registered?
    resp = `aws elbv2 describe-target-health --target-group-arn #{target_group} --targets Id=#{instance_id} --region #{REGION}`
    description = JSON.parse(resp)['TargetHealthDescriptions'].find { |data| data['Target']['Id'] == instance_id }
    description && description['TargetHealth']['State'] == 'healthy'
  end

  def deregister
    `aws elbv2 deregister-targets --target-group-arn #{target_group} --targets Id=#{instance_id} --region #{REGION}`
  end

  def wait_until_deregistered
    `aws elbv2 wait target-deregistered --target-group-arn #{target_group} --targets Id=#{instance_id} --region #{REGION}`
  end

  def target_group
    '__ARN__'
  end
end

def main
  me = App.new
  return unless me.marked_to_be_terminated?

  if me.registered?
    me.deregister
    me.wait_until_deregistered
  end
  me.stop if me.running?
end

if __FILE__ == $0
  main
end

