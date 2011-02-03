#-*- coding: utf-8 -*-

# whocares.rb
# Author: Shota Fukumori (sora_h)
# License: MIT License
# The MIT Licence {{{
#
#     (c) Shota Fukumori (sora_h) 2010
#
#     Permission is hereby granted, free of charge, to any person obtaining a copy
#     of this software and associated documentation files (the "Software"), to deal
#     in the Software without restriction, including without limitation the rights
#     to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#     copies of the Software, and to permit persons to whom the Software is
#     furnished to do so, subject to the following conditions:
# 
#     The above copyright notice and this permission notice shall be included in
#     all copies or substantial portions of the Software.
# 
#     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#     IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#     FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#     AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#     LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#     OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#     THE SOFTWARE.
# }}}

require 'rubygems'
require 'net/irc'
require 'yaml'
require_relative "../lib/whocares.rb"

class WhocaresIrcGateway < Net::IRC::Server::Session
	def self.whocares; @@whocares; end
	
	def server_name
		"whocares-irc"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		@opts.channel || "#chat"
	end

	def initialize(*args)
		super
		@@whocares ||= Whocares.new(@opts.url,
								  							:name => @opts.name,
								  							:url => @opts.url,
								  							:comment => @opts.comment,
															  :pass => @opts.password)
		@@whocares.connect unless @@whocares.connected
		@@whocares.join unless @@whocares.joined
		@names_flag = false
	end

	def on_disconnect(m)
		super
		remove_hooks
	end

	def remove_hooks
		if @hooks
			@hooks.each do |i|
				@@whocares.remove_hook(*i)
			end
		end
		@hooks = []
	end

	def on_user(m)
		super
		post @prefix, JOIN, main_channel

		remove_hooks
		@hooks << @@whocares.hook(:new_message) do |msg|
			unless msg[:user].name == @opts.name
				post msg[:user].name, PRIVMSG, main_channel, msg[:body]
			end
		end
		@hooks << @@whocares.hook(:new_pm) do |msg|
			post msg[:user].name, PRIVMSG, @nick, msg[:body]
		end
		@hooks << @@whocares.hook(:new_info) do |msg|
			case msg[:info_type]
			when :enter
				msg[:user].each do |u|
					post u.name, JOIN, main_channel unless u.name == @opts.name
				end
			when :exit
				msg[:user].each do |u|
					post u.name, QUIT, "exit"
				end
			when :disappear
				msg[:user].each do |u|
					post u.name, QUIT, "disappear"
				end
			else
				post "system", NOTICE, main_channel, msg[:body]
			end
			unless @names_flag
				on_names nil
				@names_flag = true
			end
		end

	end

	def on_names(m)
		a = @@whocares.users.map(&:name)
		a.delete(@opts.name)
		post server_name, RPL_NAMREPLY, @nick, "=", main_channel, a.join(" ")
		post server_name, RPL_ENDOFNAMES, @nick, main_channel, "End of names list"
	end

	def on_privmsg(m)
		super
		m[0].force_encoding("UTF-8")
		m[1].force_encoding("UTF-8")
		if m[0] == main_channel || /^#/ =~ m[0]
			@@whocares.post m[1]
		else #pm
			if (user = @@whocares.u(m[0]))
				if user.deny_pm?
					post m[0], NOTICE, @nick, "user is denying pm"
				else
					@@whocares.post m[1], :to => m[0]
				end
			else
				post m[0], NOTICE, @nick, "not found..."
			end
		end
	end

	def on_whois(m)
		m.params.map{|x| @@whocares.u(x)}.compact.each do |x|
			post server_name, RPL_WHOISUSER, @nick, x.name, x.deny_pm? ? "deny_pm" : "not_deny_pm", "localhost", "*", (x.comment || "No Comment Given") + "/" + (x.url || "No URL Given")
			post server_name, RPL_ENDOFWHOIS, @nick, x.name, "End of whois list"
		end
	end

	opts = {
		:port  => 6678,
		:host  => "localhost",
		:log   => nil,
		:debug => false
	}.merge(Hash[YAML.load_file(ARGV[0]).map{|k,v| [k.to_sym, v]}])

	abort "needs url" unless opts[:url]
	abort "needs name" unless opts[:name]

	Whocares.debug = opts[:debug]


	Signal.trap(:INT){
		self.whocares.disconnect if self.whocares.connected
		exit(0)
	}

	Net::IRC::Server.new(opts[:host], opts[:port], WhocaresIrcGateway, opts).start
end
