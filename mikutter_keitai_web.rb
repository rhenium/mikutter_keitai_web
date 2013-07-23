# -*- coding: utf-8 -*-
require "net/https"
require "cgi"
require "gtk2"

class LoginError < StandardError; end
IPadUserAgent = "Mozilla/5.0 (iPad;)"

Plugin.create :mikutter_suruyatsu do
  UserConfig[:keitai_web_cookie] ||= nil
  UserConfig[:keitai_web_authenticity_token] ||= nil

  def save_cookie(res)
    UserConfig[:keitai_web_cookie] = res.get_fields("Set-Cookie").map {|s| s[0...s.index(";")] }.join("; ")
    res
  end

  def http_get(url)
    uri = URI.parse(url)
    req = Net::HTTP::Get.new(uri.request_uri, {"User-Agent" => IPadUserAgent,
                                               "Cookie" => UserConfig[:keitai_web_cookie] || ""})
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    save_cookie(http.request(req))
  end

  def http_post(url, hash = {})
    uri = URI.parse(url)
    req = Net::HTTP::Post.new(uri.request_uri, {"User-Agent" => IPadUserAgent,
                                               "Cookie" => UserConfig[:keitai_web_cookie] || ""})
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    data = hash.map {|k, v| "#{k.to_s}=#{CGI.escape(v.to_s)}" }.join("&")
    save_cookie(http.request(req, data))
  end

  def login(username, password)
    f_body = http_get("https://twtr.jp/login").body
    UserConfig[:keitai_web_authenticity_token] = f_body.match(/name="authenticity_token" value="([A-Za-z0-9=+\/]+)"/)[1]

    res = http_post("https://twtr.jp/login",
                    authenticity_token: UserConfig[:keitai_web_authenticity_token],
                    login: username,
                    password: password)
    if res.code.to_i != 302
      raise LoginError
    end
  end

  def post(str, reply_to)
    res = http_post("https://twtr.jp/statuses/create",
                    authenticity_token: UserConfig[:keitai_web_authenticity_token],
                    text: str,
                    in_reply_to: reply_to)
    if res.code.to_i != 302
      raise LoginError
    end
  end

  def retweet(username, id)
    res = http_post("https://twtr.jp/#{username}/status/#{id}/retweet",
                    authenticity_token: UserConfig[:keitai_web_authenticity_token],
                    screen_name: username,
                    id: id)
    if res.code.to_i != 302
      raise LoginError
    end
  end

  def get_password
    dialog = Gtk::Dialog.new("Twitter Authentication",
                             nil,
                             nil,
                             [Gtk::Stock::OK, Gtk::Dialog::RESPONSE_ACCEPT],
                             [Gtk::Stock::CANCEL, Gtk::Dialog::RESPONSE_REJECT])

    label = Gtk::Label.new
    label.wrap = true
    label.set_markup("<span font_desc=\"18\">Mobile Web つかってツイートするやつ</span>\n\n" +
                     "まだ認証されていません。パスワードを入力してください。\n\n")
    dialog.vbox.add(label)
    entry = Gtk::Entry.new
    entry.visibility = false
    hbox = Gtk::HBox.new(false, 10)
    hbox.pack_end(entry, false, false, 0)
    hbox.pack_end(Gtk::Label.new("password"), false, false, 0)
    dialog.vbox.add(hbox)
    dialog.show_all

    input = ""
    dialog.run do |response|
      case response
      when Gtk::Dialog::RESPONSE_ACCEPT
        input = entry.text
      end
      dialog.destroy
    end

    input
  end

  def initialize
    if UserConfig[:keitai_web_authenticity_token] == nil || UserConfig[:keitai_web_cookie] == nil
      login(Service.primary.user.to_s, get_password)
    end
  end

  command(:keitai_web_post,
          name: "Keitai Web で投稿",
          condition: -> _ { true },
          visible: true,
          role: :postbox) do |opt|
    begin
      initialize

      postbox = Plugin.create(:gtk).widgetof(opt.widget)
      Thread.new do
        text = postbox.widget_post.buffer.text
        text += UserConfig[:footer] if postbox.__send__(:add_footer?)

        begin
          Plugin.call(:before_postbox_post, text)

          watch = postbox.__send__(:service)
          if watch.respond_to?(:[])
            postbox.widget_post.sensitive = false
            postbox.widget_post.editable = false
            post(text, watch[:id])
            postbox.__send__(:destroy)
          else
            postbox.widget_post.buffer.text = ""
            post(text, 0)
          end
        rescue LoginError => e
          UserConfig[:keitai_web_authenticity_token] = nil
          Plugin.call(:update, nil, [Message.new(message: "login error", system: true)])
        end
      end
    rescue Exception => e
      p $!
      puts $@
      Plugin.call(:update, nil, [Message.new(message: e.to_s, system: true)])
    end
  end

  command(:keitai_web_retweet,
          name: "Keitai Web で RT",
          condition: Plugin::Command[:CanReplyAll],
          visible: true,
          role: :timeline) do |opt|
    begin
      initialize
      opt.messages.each do |m|
        Thread.new do
          retweet(m.message.idname, m.message[:id])
        end
      end
    rescue LoginError => e
      UserConfig[:keitai_web_authenticity_token] = nil
      Plugin.call(:update, nil, [Message.new(message: "login error", system: true)])
    rescue Exception => e
      Plugin.call(:update, nil, [Message.new(message: e.to_s, system: true)])
    end
  end
end

