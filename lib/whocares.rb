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
require 'open-uri'
require 'json'
require 'date'

class Whocares
  @@debug = false
  def self.debug; @@debug; end
  def self.debug=(x); @@debug = x; end

  class ConnectError < Exception; end

  module API
    module Joint
      def join(base="",params={})
        base + self + "?" + params.map do |k,v|
          "#{URI.escape(k.to_s)}=#{URI.escape(v.to_s)}"
        end.join("&")
      end
    end

    JOIN = "/enter"
    PART = "/exit"
    POLL = "/comet/poll"
    POST = "/send"

    [JOIN,PART,POLL,POST].each do |x|
      class << x; include Joint; end
    end
  end

  def initialize(url, option={})
    @url = url.sub(/\/$/,"").sub(/^https/,"http")
    @url = "http://" + @url if /^http:\/\// !~ @url

    d "url", @url

    @option = {}.merge(option)
    raise ArgumentError, "name is needed" unless @option[:name]

    @connected = false

    @endpoint = nil
    @cookie = nil
    @polling = nil
    @v = ""
    @hooks = {}
    @count = {}
    @users = []
    @log = []
  end

  def connect
    open("#{@url}/") do |io|
      begin
        @endpoint = io.read.match(/<frame style="border:0;margin:0;padding:0" src="(.+?)" noresize="noresize" scrolling="no"/).captures[0].sub(/\/$/,"")
        @cookie = Hash[io.meta["set-cookie"].split(/ ?[;,] ?/).map{|x|x.split(/=/)}]
        d "Connect:", @endpoint, @cookie
        class << @cookie
          def join
            self.map do |k,v|
              "#{k}=#{v}"
            end.join("; ")
          end
        end
      rescue NoMethodError
        raise ConnectError, "Can't get endpoint"
      end
    end
    @connected = true
    poll_start
    self
  end

  def disconnect
    d "Disconnect"
    poll_stop
    @connected = false
    @endpoint = nil
    @cookie = nil
    @users = []
    @count = {}
    @log = []
  end

  def join
    connect unless @connected

    j = URI.parse(API::JOIN.join(@endpoint))

    param = {
      "etm" => (Time.now.to_f*1000).to_i,
      "plaf" => "MacIntel,Unknown",
      "cb" => "parent.chatx.cb",
      "logLevel" => "1",
      "name" => @option[:name]
    }
    [:url,:comment,:pass].each {|x| param[x.to_s] = @option[x] if @option[x] }
    param["denyPm"] = "1" if @option[:deny_pm]

    d "Join", param

    Net::HTTP.start(j.host,j.port) do |http|
      http.post(j.path, form(param),
                "Cookie" => @cookie.join)
    end
  end

  def part
    j = URI.parse(API::PART.join(@endpoint))
    Net::HTTP.start(j.host,j.port) do |http|
      http.post(j.path, form("cb" => "parent.chatx.cb"),
                "Cookie" => @cookie.join)
    end
  end

  def post(body, option={})
    j = URI.parse(API::POST.join(@endpoint))
    params = {
      "cb" => "parent.chatx.cb",
      "msg" => body,
      "fontSize" => "",
      "color" => "#000000",
      "pm" => ""
    }
    params["color"] = option[:color] if option[:color]
    eid = option[:pm]   || option[:eid] || \
          option[:user] || option[:to]
    params["eid"] = u(eid) if eid

    d "Post", params

    Net::HTTP.start(j.host,j.port) do |http|
      http.post(j.path, form(params),
                "Cookie" => @cookie.join)
    end
  end

  def hook(name, option={}, &block)
    @hooks[name] ||= []
    @hooks[name] << {:option => option, :proc => block}
    self
  end

  def user(id)
    @users.find do |x|
      x.id == id
    end || @users.find do |x|
      x.name == id
    end
  end
  alias u user

  attr_reader :hooks, :users, :count, :log


  private

  def call_hook(name, *args)
    @hooks[name] ||= []
    @hooks[name].each do |h|
      if block_given?
        next unless yield h[:option]
      end
      h[:proc].call *args
    end
    d "Hook:", name, args
  end

  def poll_start
    return if @polling
    @polling = Thread.start do
      begin
        loop do
          d "Poll.."
          poll API::POLL.join(@endpoint, :v => @v)
          sleep 0.2
        end
      rescue Exception => e
        puts "#{e.class}: #{e.message}"
        puts e.backtrace
      end
    end
  end

  def poll_stop
    @polling.kill
    @polling = nil
  end

  def poll(url)
    open(url, {"Cookie" => @cookie.join}) do |io|
      j = JSON.parse(io.read) rescue return

      d "Poll", j

      @v = j["v"] if j["v"]

      return if j["type"] == "noop"

      if j["type"] == "error"
        Thread.new do
          call_hook :will_reconnect
          disconnect
          sleep 1
          connect
          call_hook :reconnected
        end
        return
      end

      if j["users"]
        @users = j["users"].map do |u|
          User.new(u)
        end
      end

      if j["logs"]
        case j["type"]
        when "diff"
          @log.unshift(*(j["logs"].map do |l|
            h = process_log(l)
            if h[:type] == :info
              call_hook(:new_message, h) {|opt| h[:with_info] }
              call_hook(:new_info, h)
            else
              call_hook(:new_message, h)
            end
            h
          end))
        when "replace"
          @log = j["logs"].map do |l|
            h = process_log(l)
            if h[:type] == :info
              call_hook(:replace_message, h) {|opt| h[:with_info] }
              call_hook(:replace_info, h)
            else
              call_hook(:replace_message, h)
            end
            h
          end
        end
      end

      if j["count"]
        [:users,:roms].each do |x|
          @count[x] = j["count"][x.to_s] || @count[x] || 0
        end
      end
    end
  end

  def form(params={})
    params.map do |k,v|
      "#{URI.escape(k.to_s)}=#{URI.escape(v.to_s)}"
    end.join("&")
  end

  def process_log(h)
    l = {}
    l[:id] = h["seqno"]
    l[:time] = Time.parse(h["ts"])
    l[:body] = h["tag"]
    l[:type] = h["type"].to_sym 
    l[:info_type] = h["infoType"].to_sym if h["infoType"]
    l[:to] = h["toUser"] if h["toUser"]
    l[:user] = u(h["eid"])
    l
  end

  def d(*args)
    puts args.map(&:inspect).join(", ") if @@debug
  end

  class User
    def initialize(u)
      @deny_pm = u["denyPm"]
      @term = u["term"]
      @name = u["name"]
      @id = u["eid"]
      @url = u["linkUrl"]
      @comment = u["comment"]
    end

    def deny_pm?; @deny_pm; end

    attr_reader :term, :name, :id, :url, :comment 

  end
end
