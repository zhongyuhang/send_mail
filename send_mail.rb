require 'mail'
require 'active_record'

class LocalTable < ActiveRecord::Base
  self.pluralize_table_names  = false
  self.abstract_class         = true
  def failed_type
    return if self.status != 'failed'
    log = self.class.table_name == "lawyer_match_request" ? self.latest_log.message : self.process_log
    failed_type = [
      'Temporary failure in name resolution',
      'Response code = 503',
      'Response code = 502',
      'Response code = 500',
      'Response code = 404',
      'unknown attribute.*?primary_persona_flag_v2',
    ]
    type = failed_type.find{|e| /#{e}/ =~ log}
    type = type.nil? ? "unclassified error, id = #{self.id}" : type
    return type
  end
end

class LawyerMatchRequest < LocalTable
  has_many :lawyer_match_request_logs
  def latest_log
    self.lawyer_match_request_logs.sort_by(&:updated_at).last
  end
end

class LawyerMatchRequestLog < LocalTable
  belongs_to :lawyer_match_request
end

class LmbRequest < LocalTable ; end

class ForagerRequest < LocalTable ; end

ActiveRecord::Base.establish_connection(YAML.load_file("db.yml"))

def set_tbody(objects)
  body = ""
  h = {}
  unclassify_ids = []
  objects.each do |o|
    if o.failed_type =~ /unclassified error.*?(\d+)/
      unclassify_ids << $1
    else
      h[o.failed_type] = h[o.failed_type] ? h[o.failed_type] + 1 : 1
    end
  end
  h.each do |k,v|
    body.concat("<tr><td>#{k}</td><td>#{v}</td></tr>")
  end
  body.concat("<tr><td>unclassified error</td><td>#{unclassify_ids.size}[#{unclassify_ids.join(',')}]</td></tr>")
  return body
end

def set_css
  "<style>
      .rtable {display: inline-block;vertical-align: top;max-width: 100%;overflow-x: auto;white-space: nowrap;border-collapse: collapse;border-spacing: 0;}
      .rtable td:first-child,
      .rtable--flip tbody tr:first-child {background-image: linear-gradient(to right, rgba(255,255,255, 1) 50%, rgba(255,255,255, 0) 100%);background-repeat: no-repeat;background-size: 20px 100%;}
      .rtable td:last-child,
      tbody tr:last-child {background-repeat: no-repeat;background-position: 100% 0;background-size: 20px 100%;}
      .rtable th {font-size: 11px;text-align: left;text-transform: uppercase;background: #CB1B45;}
      .rtable th,
      .rtable td {padding: 6px 12px; border: 1px solid #d9d7ce;}  
      body {margin: 0;padding: 25px;color: #494b4d;font-size: 14px;line-height: 20px;}
      h1, h2, h3 {margin: 0 0 10px 0;color: #000000;}
      h1 {font-size: 25px;line-height: 30px;}
      table {margin-bottom: 30px;}
      a {color: #ff6680;}
      code {background: #fffbcc;font-size: 12px;}
    </style>"
end

def set_table(objects)
  puts "set size #{objects.size}"
  <<-EOF
    <h1>ForagerReqeust Failed Record</h1>
    <table class="rtable">
      <thead>
        <tr>
          <th>Failed Type</th>
          <th>Count</th>
        </tr>
      </thead>
      <tbody>
        #{set_tbody(objects)}
      </tbody>
    </table>
  EOF
end

def set_body
  # set_lmrs_table + set_lrs_table + set_frs_table
  str_body = ""
  [LawyerMatchRequest, LmbRequest, ForagerRequest].map{
    |model| 
    str_body += set_table(model.where("status = 'failed' and updated_at > '#{8.day.ago}'"))
  }
  return set_css + str_body
end

def send_mail
  smtp = { 
    :address => "smtp.gmail.com",
    :port => 587, 
    :domain => "gmail.com",
    :user_name => "autoforager.avvo@gmail.com",
    :password => "avvo.com2",
    :enable_starttls_auto => true
  }
  Mail.defaults { delivery_method :smtp, smtp }
  mail = Mail.new do
    from "autoforager.avvo@gmail.com"
    to ["1076525788@qq.com","18582487349@163.com"]
    subject "[#{Time.now}] Daily Sync Error Record"
    content_type 'text/html; charset=UTF-8'
    body set_body
  end
  mail.deliver!
end

send_mail
