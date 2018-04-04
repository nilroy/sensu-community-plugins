#!/usr/bin/env ruby
#
# CHANGELOG:
# * 0.4.0:
#   - Adds ability to specify a list of states an individual client can have in
#     EC2. If none is specified, it filters out 'terminated' and 'stopped'
#     instances by default.
#   - Updates how we are "puts"-ing to the log.
# * 0.3.0:
#   - Updates handler to additionally filter stopped instances.
# * 0.2.1:
#   - Updates requested configuration snippets so they'll be redacted by
#     default.
# * 0.2.0:
#   - Renames handler from chef_ec2_node to ec2_node
#   - Removes Chef-related stuff from handler
#   - Updates documentation
# * 0.1.0:
#   - Initial release
#
# This handler deletes a Sensu client if it's been stopped or terminated in EC2.
# Optionally, you may specify a client attribute `ec2_states`, a list of valid
# states an instance may have.
#
# NOTE: The implementation for correlating Sensu clients to EC2 instances may
# need to be modified to fit your organization. The current implementation
# assumes that Sensu clients' names are the same as their instance IDs in EC2.
# If this is not the case, you can either sub-class this handler and override
# `ec2_node_exists?` in your own organization-specific handler, or modify this
# handler to suit your needs.
#
# Requires the following Rubygems (`gem install $GEM`):
#   - sensu-plugin
#   - aws-sdk
#
# Requires a Sensu configuration snippet:
#   {
#     "aws": {
#       "access_key": "adsafdafda",
#       "secret_key": "qwuieohajladsafhj23nm",
#       "region": "us-east-1c"
#     }
#   }
#
# Or you can set the following environment variables:
#   - AWS_ACCESS_KEY_ID
#   - AWS_SECRET_ACCESS_KEY
#   - EC2_REGION
#
#
# To use, you can set it as the keepalive handler for a client:
#   {
#     "client": {
#       "name": "i-424242",
#       "address": "127.0.0.1",
#       "keepalive": {
#         "handler": "ec2_node"
#       },
#       "subscriptions": ["all"]
#     }
#   }
#
# You can also use this handler with a filter:
#   {
#     "filters": {
#       "ghost_nodes": {
#         "attributes": {
#           "check": {
#             "name": "keepalive",
#             "status": 2
#           },
#           "occurrences": "eval: value > 2"
#         }
#       }
#     },
#     "handlers": {
#       "ec2_node": {
#         "type": "pipe",
#         "command": "/etc/sensu/handlers/ec2_node.rb",
#         "severities": ["warning","critical"],
#         "filter": "ghost_nodes"
#       }
#     }
#   }
#
# Copyleft 2013 Yet Another Clever Name
#
# Based off of the `chef_node` handler by Heavy Water Operations, LLC
#
# Released under the same terms as Sensu (the MIT license); see
# LICENSE for details

require 'timeout'
require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'sensu-handler'
require 'aws-sdk'

class Ec2Node < Sensu::Handler
  def filter; end

  def handle
    # #YELLOW
    unless ec2_node_exists? # rubocop:disable UnlessElse
      delete_sensu_client!
    else
      puts "[EC2 Node] #{@event['client']['name']} appears to exist in EC2"
    end
  end

  def delete_sensu_client!
    response = api_request(:DELETE, '/clients/' + @event['client']['name']).code
    deletion_status(response)
  end

  def ec2_node_exists?
    states = acquire_valid_states
    filters = []
    filters << { name: 'tag:Role', values: [@event['client']['role']] }
    filters << { name: 'tag:Environment', values: [@event['client']['environment']] }
    filters << { name: 'tag:Name', values: [@event['client']['name']] }
    instances = ec2.describe_instances(filters: filters)
    filtered_instances = []

    loop do
      instances.reservations.each do |r|
        r.instances.each do |i|
          filtered_instances << i if states.include?(i.state.name)
        end
      end

      # If next_token is set, fetch a new set of servers
      break unless instances.next_token
      instances = ec2.describe_instances(next_token: instances.next_token)
    end
    filtered_instances.empty? ? false : true
  end

  def ec2
    @ec2 ||= begin
      region = settings['aws']['region'] || ENV['EC2_REGION']
      Aws::EC2::Client.new(region: region)
    end
  end

  def deletion_status(code)
    case code
    when '202'
      puts "[EC2 Node] 202: Successfully deleted Sensu client: #{@event['client']['name']}"
    when '404'
      puts "[EC2 Node] 404: Unable to delete #{@event['client']['name']}, doesn't exist!"
    when '500'
      puts "[EC2 Node] 500: Miscellaneous error when deleting #{@event['client']['name']}"
    else
      puts "[EC2 Node] #{res}: Completely unsure of what happened!"
    end
  end

  def acquire_valid_states
    if @event['client'].key?('ec2_states')
      @event['client']['ec2_states']
    else
      ['running']
    end
  end
end
