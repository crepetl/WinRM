# -*- encoding: utf-8 -*-
#
# Copyright 2016 Shawn Neal <sneal@sneal.net>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative 'retryable'
require_relative '../http/transport'
require_relative '../wsmv/cleanup_command'
require_relative '../wsmv/close_shell'
require_relative '../wsmv/command'
require_relative '../wsmv/command_output'
require_relative '../wsmv/command_output_processor'
require_relative '../wsmv/create_shell'
require_relative '../wsmv/soap'

module WinRM
  module Shells
    # Base class for remote shell
    class Base
      include Retryable

      # Create a new Cmd shell
      # @param connection_opts [ConnectionOpts] The WinRM connection options
      # @param transport [HttpTransport] The WinRM SOAP transport
      # @param logger [Logger] The logger to log diagnostic messages to
      def initialize(connection_opts, transport, logger)
        @connection_opts = connection_opts
        @transport = transport
        @logger = logger
        @command_count = 0
      end

      attr_reader :shell_id, :shell_uri, :connection_opts, :transport, :logger

      # Runs the specified command with optional arguments
      # @param command [String] The command or executable to run
      # @param arguments [Array] The optional command arguments
      # @param block [&block] The optional callback for any realtime output
      def run(command, arguments = [], &block)
        open if @command_count > connection_opts[:max_commands] || !shell_id
        @command_count += 1
        command_id = send_command(command, arguments)
        command_output(command_id, &block)
      ensure
        cleanup_command(command_id) if command_id
      end

      def close
        return unless shell_id
        self.class.close_shell(connection_opts, transport, shell_id)
        remove_finalizer
        @shell_id = nil
      end

      protected

      def send_command(command, arguments)
        cmd_msg = command_message(shell_id, command, arguments)
        transport.send_request(cmd_msg.build)
        cmd_msg.command_id
      end

      def output_processor
        raise NotImplementedError
      end

      def command_message(_shell_id, _command, _arguments)
        raise NotImplementedError
      end

      def open_shell
        raise NotImplementedError
      end

      private

      def command_output(command_id, &block)
        output_processor.command_output(shell_id, command_id, &block)
      end

      def cleanup_command(command_id)
        cleanup_msg = WinRM::WSMV::CleanupCommand.new(
          connection_opts,
          shell_uri: shell_uri,
          shell_id: shell_id,
          command_id: command_id)
        transport.send_request(cleanup_msg.build)
      end

      def open
        close
        retryable(connection_opts[:retry_limit], connection_opts[:retry_delay]) do
          @shell_id = open_shell
        end
        add_finalizer
        @command_count = 0
      end

      def add_finalizer
        ObjectSpace.define_finalizer(
          self,
          self.class.finalize(connection_opts, transport, shell_id))
      end

      def remove_finalizer
        ObjectSpace.undefine_finalizer(self)
      end
    end
  end
end