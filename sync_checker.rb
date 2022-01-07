require 'mail'
require 'active_record'

WORKER_INFO = {
  'directory-attorney-availability' => 'directory_attorney_availability_production.log',
  'factual-data-to-avvo' => 'factual_data_to_avvo_production.log',
  'kafka-consumer' => 'kafka_consumers_production.log',
}
TIME_START = Time.now - 32 * 60 * 60
TIME_END = Time.now - 8 * 60 * 60
LOCAL_KUBE_PATH = File.join(File.expand_path('~'), '.kube/')
LOCAL_LOG_PATH = File.join(File.expand_path('~'), '.kube/log/')
PRODUCTION_LOG_PATH = "/srv/martindale-interfaces/log/"
TABLE_STYLE = "border-collapse: collapse;border-spacing: 0;empty-cells: show;border: 1px solid #cbcbcb;"
THEAD_STYLE = "background-color: #e0e0e0;color: #000;text-align: left;vertical-align: bottom;"
TH_STYLE =  "padding: 0;border-left: 1px solid #cbcbcb;border-width: 0 0 0 1px;font-size: inherit;margin: 0;overflow: visible;padding: .5em 1em;"
TD_STYLE = "border-left: 1px solid #cbcbcb;border-bottom: 1px solid #cbcbcb;padding: .5em 1em;"
TR_STYLE = "border-bottom-width: 0;"
GO_TO_KUBE_DIR = "cd #{LOCAL_KUBE_PATH};"
SWITCH_NAMESPACE_TO_PRODUCTION = "kubectl config set-context --current --namespace=production >/dev/null 2>&1;"

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

class LawyerMatchRequestLog < LocalTable ; end

class LmbRequest < LocalTable ; end

class ForagerRequest < LocalTable ; end

def send_mail
  config = YAML.load_file("config.yml")
  ActiveRecord::Base.establish_connection(config['db'])
  Mail.defaults { delivery_method :smtp, config['smtp'] }
  mail = Mail.new do
    from "Avvo MH Sync Checker <autoforager.avvo@gmail.com>"
    to config['to']
    subject "[#{Date.today.strftime('%Y-%m-%d')}] Daily sync report"
    html_part do
      content_type 'text/html; charset=UTF-8'
      body get_time_part + get_html_for_logs + get_html_for_tables
    end
  end
  mail.deliver!
end

def get_time_part
  return "<h2>From #{TIME_START.strftime("%Y-%m-%d %H:%M:%S")} to #{TIME_END.strftime("%Y-%m-%d %H:%M:%S")} (PST)</h2>"
end

def get_html_for_logs
  # pods =>
  # "pod/martindale-interfaces-58d8c98c7f-s4mkq\npod/martindale-interfaces-aux-redis-76d695bdbc-wlbxb\n
  #  pod/martindale-interfaces-worker-directory-attorney-availabilixkpj9\n
  #  pod/martindale-interfaces-worker-factual-data-to-avvo-659786c8cnfsv\n
  #  pod/martindale-interfaces-worker-kafka-consumer-6f44b856bf-qgxz5\n
  #  pod/martindale-interfaces-worker-resque-scheduler-db7c89695-bp9x5\n
  #  pod/martindale-interfaces-worker-resque-workers-64d55d7566-9vxq9\n
  #  pod/martindale-interfaces-worker-resque-workers-64d55d7566-gd8j7\n
  #  pod/martindale-interfaces-worker-resque-workers-75b5475f9f-qh5fv\n
  #  pod/martindale-interfaces-worker-resque-workers-7c5dd9b648-hqhp5\n
  #  pod/martindale-interfaces-worker-resque-workers-7c5dd9b648-xzw4g\n"
  pods = `
    #{GO_TO_KUBE_DIR}
    #{SWITCH_NAMESPACE_TO_PRODUCTION}
    kubectl get pods -o=name|grep martindale
  `
  html_for_logs = []
  WORKER_INFO.each do |worker, log_name|
    # e.g.
    # pod    = martindale-interfaces-worker-directory-attorney-availabilixkpj9
    # worker = directory-attorney-availability
    # pod name does not show full worker name directory-attorney-availability
    # only the first 58 chars and 5 random chars displayed
    if /#{("martindale-interfaces-worker-" + worker)[0,58]}.*/ =~ pods
      copy_log_from_pod($&, log_name)
      html_for_logs << get_html_for_log(log_name)
    end
  end
  return html_for_logs.join
end

def copy_log_from_pod(pod_name, log_name)
  `
  #{GO_TO_KUBE_DIR}
  #{SWITCH_NAMESPACE_TO_PRODUCTION}
  kubectl cp #{pod_name}:#{PRODUCTION_LOG_PATH}#{log_name} #{LOCAL_LOG_PATH}#{log_name}
  `
end

def get_html_for_log(log_name)
  tbody, count = get_tbody_for_log_and_number_of_message(log_name)
  return get_html(log_name, tbody, count)
end

def get_tbody_for_log_and_number_of_message(log_name)
  h = {}
  message_count = 0
  regex = log_name == 'kafka_consumers_production.log' ? /INFO.*:\s*(.*)/ : /DEBUG.*AvvoKafka::Message.*avvoProfessionalID.*?(\d+)/
  File.open(LOCAL_LOG_PATH + log_name).each do |line|
    time_str = line.scan(/.*?\[(.*?)\./).flatten.first # e.g.: "E, [2021-12-20T02:42:00.707457 #1] ERROR -- :" => "2021-12-20T02:42:00"
    next if time_str.nil?
    next if !(TIME_START.strftime("%Y-%m-%dT%H:%M:%S") < time_str && TIME_END.strftime("%Y-%m-%dT%H:%M:%S") > time_str)
    if line =~ /^E.*?ERROR.*?:\s+(.*)/i
      error = $1
      h[error] = h[error] ? h[error] + 1 : 1
    else
      message_count += 1 if line =~ regex
    end
  end
  return h.empty? ? nil : h.map{|error, count|
    "<tr style = '#{TR_STYLE}'>
     <td style = '#{TD_STYLE}'>#{error}</td>
     <td style = '#{TD_STYLE}'>#{count}</td>
     </tr>"
  }.join, message_count
end

def get_html_for_tables
  [LawyerMatchRequestLog, LmbRequest, ForagerRequest].map{|table_name| get_html_for_table(table_name)}.join
end

def get_html_for_table(table_name)
  sql_statement = "#{table_name == LawyerMatchRequestLog ? "message like 'failed%'" : "status = 'failed'"}  and updated_at > '#{TIME_START}'"
  tbody = get_tbody_for_table table_name.where(sql_statement).order("id")
  count = table_name.where("updated_at > '#{TIME_START}'").size
  return get_html(table_name, tbody, count)
end

def get_tbody_for_table(rows)
  return if rows.empty?
  tbody = ""
  h = {}
  rows.map {|row| h[row.failed_type] = h[row.failed_type] ? h[row.failed_type].push(row.id) : [row.id]}
  return if h.empty?
  h.sort_by {|failed_type,ids| [ids.size, failed_type]}.reverse.to_h.each do |failed_type,ids|
    tbody.concat("
      <tr style = '#{TR_STYLE}'><td style = '#{TD_STYLE}'>#{failed_type}</td>
      <td style = '#{TD_STYLE}'>#{ids.size}</td>
      <td style = '#{TD_STYLE}'>#{ids.size < 4 ? ids.join('/') : ids[0,3].join('/') + '/...'}</td></tr>")
  end
  return tbody
end

def get_html(title, tbody, count)
  return <<-EOF
    <h2>#{title.class == String ? title : '[' + title.to_s + ']'}</h2>
    <p>Count: #{count}</p>
    <p>Error: #{tbody.nil? ? "n/a </p>" :
    "<table style = '#{TABLE_STYLE}'>
      <thead style = '#{THEAD_STYLE}'>
        <tr style = '#{TR_STYLE}'>
          <th style = '#{TH_STYLE}'>FAILED TYPE</th>
          <th style = '#{TH_STYLE}'>COUNT</th>
          #{title.class == String ? nil : "<th style = '#{TH_STYLE}'>ID</th"}
        </tr>
      </thead>
        #{tbody}
      <tbody>
      </tbody>
    </table>"}
  EOF
end

send_mail
