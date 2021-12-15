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
      'unknown attribute `primary_persona_flag_v2`',
    ]
    type = failed_type.find{|e| /#{e}/ =~ log}
    return type.nil? ? "unclassified errors" : type
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
  tbody = ""
  h = {}
  objects.each do |o|
    if h[o.failed_type]
      h[o.failed_type][0] += 1
      h[o.failed_type][1] << o.id
    else
      h[o.failed_type] = [1, [o.id]]
    end
  end
  return if h.empty?
  h = h.sort_by {|k,v| [v[0], k]}.reverse.to_h
  h.each do |k,v|
    tbody.concat("<tr><td>#{k}</td><td>#{v[0]}</td><td>#{v[1].size < 3 ? v[1].join('/') : v[1][0,3].join('/') + '/...'}</td></tr>")
  end
  return tbody
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
      h2 {font-size: 25px;line-height: 30px;}
      table {margin-bottom: 30px;}
      a {color: #ff6680;}
      code {background: #fffbcc;font-size: 12px;}
    </style>"
end

def set_table(klass)
  objects = klass.where("status = 'failed' and updated_at > '#{9.day.ago}'")
  tbody = set_tbody(objects)
  return "<h2>#{klass.to_s}</h2><p>N/A</p>" if tbody.nil?
  <<-EOF
    <h2>#{klass.to_s}</h2>
    <table class="rtable">
      <thead>
        <tr>
          <th>FAILED TYPE</th>
          <th>COUNT</th>
          <th>ID</th
        </tr>
      </thead>
      <tbody>
      #{tbody}
      </tbody>
    </table>
  EOF
end

def set_body
  str_body = ""
  [LawyerMatchRequest, LmbRequest, ForagerRequest].map{
    |model| 
    str_body += set_table(model)
  }
  return set_css + str_body
end

def cp_file_from_pod
  puts 'cp_file_from_pod begin'
  system("
    cd /home/dyson/.kube;
    kubectl config set-context --current --namespace=und-618;
    kubectl cp martindale-interfaces-worker-foraged-data-to-mh-8ffdd9dc8-ks8vv:/srv/martindale-interfaces/log/foraged_data_to_mh_ec2.log /home/dyson/.kube/yh/foraged_data_to_mh_ec2.log;
    ")
  puts 'cp_file_from_pod end'
end

def set_log
  cp_file_from_pod
  debug_count = 0
  pg_no_connection_error_count = 0
  File.open('/home/dyson/.kube/yh/foraged_data_to_mh_ec2.log').each do |line|
    debug_count += 1 if line =~ /^D,/i
    pg_no_connection_error_count += 1 if line =~ /PG::UnableToSend: no connection to the server/
  end
  return "<h2>Foraged Data To Mh Log</h2><p>N/A</p>"
  return <<-EOF
    <h2>Foraged Data To Mh Log</h2>
    <table class="rtable">
      <thead>
        <tr>
          <th>FAILED TYPE</th>
          <th>COUNT</th>
        </tr>
      </thead>
      <tbody>
      <tr>
      <td>PG::UnableToSend: no connection to the server</td>
      <td>#{pg_no_connection_error_count}</td>
      <td>debug line</td>
      <td>#{debug_count}</td>
      <tr>
      </tbody>
    </table>
  EOF
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
    # to ["18582487349@163.com","yegang.avvo@gmail.com","hewang.cs@gmail.com"]
    to ["18582487349@163.com"]
    subject "[#{Date.today.strftime('%Y-%m-%d')}] Daily report for failed sync"
    html_part do
      content_type 'text/html; charset=UTF-8'
      body set_log + set_body
    end
  end
  mail.deliver!
end

send_mail
