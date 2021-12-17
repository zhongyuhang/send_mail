require 'mail'
require 'active_record'

LOG_ERROR_TYPE = []
BASE_LOG_PATH = "/home/yuhang/.kube/log/"
WORKER_LOG_FILE_NAME = [
  'factual_data_to_avvoproduction.log',
  'directory_attorney_availability_production.log',
  'kafka_consumers_production.log',
]
class LocalTable < ActiveRecord::Base
  self.pluralize_table_names  = false
  self.abstract_class         = true
  def failed_type
    log = self.class.table_name == "lawyer_match_request_log" ? self.message : self.process_log
    failed_type = [
      'Temporary failure in name resolution',
      'Response code = (\d{3})',
      'unknown attribute `primary_persona_flag_v2`',
      'Access denied for user',
      'bad URI',
    ]
    type = failed_type.find{|e| /#{e}/i =~ log}
    type = "Response code = #{$1}" if type == 'Response code = (\d{3})'
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

def send_mail
  # cp_file_from_pod_to_local
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
    from "Avvo MH Sync Checker <autoforager.avvo@gmail.com>"
    to ["18582487349@163.com","yegang.avvo@gmail.com","hewang.cs@gmail.com"]
    subject "[#{Date.today.strftime('%Y-%m-%d')}] Daily report for failed sync"
    html_part do
      content_type 'text/html; charset=UTF-8'
      # body set_css + get_worker_log_table + get_request_table
      body set_css + get_worker_log_table + get_request_table
      # body set_css + get_request_table
    end
  end
  mail.deliver!
end

def cp_file_from_pod_to_local
  puts 'cp_file_from_pod begin'
  system("
    cd /home/yuhang/.kube;
    kubectl config set-context --current --namespace=production;
    kubectl cp martindale-interfaces-worker-foraged-data-to-mh-8ffdd9dc8-ks8vv:/srv/martindale-interfaces/log/foraged_data_to_mh_ec2.log /home/yuhang/.kube/yh/foraged_data_to_mh_ec2.log;
    ")
  puts 'cp_file_from_pod end'
end

def get_worker_log_table
  h = {}
  WORKER_LOG_FILE_NAME.each do |file_name|
    pg_no_connection_error_count = 0
    File.open(BASE_LOG_PATH + file_name).each do |line|
      pg_no_connection_error_count += 1 if line =~ /PG::UnableToSend: no connection to the server/
    end
    h[file_name] = ['PG::UnableToSend: no connection to the server', pg_no_connection_error_count] if pg_no_connection_error_count != 0
  end
  return set_work_log_table(h)
end

def set_work_log_table(objects)
  tbody = set_work_log_tbody(objects)
  return fill_out_worker_log_table(tbody)
end

def set_work_log_tbody(objects)
  return if objects.empty?
  tbody = ""
  objects.each do |k,v|
    tbody.concat("<tr><td>#{k}</td><td>#{v[0]}</td><td>#{v[1]}</td></tr>")
  end
  return tbody
end

def fill_out_worker_log_table(tbody)
  return "<h2>Work Log</h2><p>N/A</p>" if tbody.nil?
  return <<-EOF
  <h2>Worker Log</h2>
  <table class="rtable" border=1>
    <thead>
      <tr>
        <th>LOG NAME</th>
        <th>FAILED TYPE</th>
        <th>COUNT</th>
      </tr>
    </thead>
    <tbody>
    #{tbody}
    </tbody>
  </table>
  EOF
end

def get_request_table
  [LawyerMatchRequestLog, LmbRequest, ForagerRequest].map{|model| set_request_table(model) }.join
end

def set_request_table(klass)
  sql_statement = if klass == LawyerMatchRequestLog
    "message like 'failed%' and updated_at > '#{1.day.ago}'"
  else
    "status = 'failed' and updated_at > '#{1.day.ago}'"
  end
  objects = klass.where(sql_statement).order("id")
  tbody = set_request_tbody(objects)
  return fill_out_request_table(klass, tbody)
end

def set_request_tbody(objects)
  return if objects.empty?
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
  # return if h.empty?
  h = h.sort_by {|k,v| [v[0], k]}.reverse.to_h
  h.each do |k,v|
    tbody.concat("<tr><td>#{k}</td><td>#{v[0]}</td><td>#{v[1].size < 4 ? v[1].join('/') : v[1][0,3].join('/') + '/...'}</td></tr>")
  end
  return tbody
end

def fill_out_request_table(title, tbody = nil)
  return "<h2>#{title.to_s}</h2><p>N/A</p>" if tbody.nil?
  return <<-EOF
    <h2>#{title.to_s}</h2>
    <table class="rtable" border=1>
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

send_mail
