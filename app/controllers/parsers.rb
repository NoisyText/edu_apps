require 'nokogiri'
module LtiXmlParser
  CANVAS_PLATFORM = 'canvas.instructure.com'
  BLTI_NAMESPACE = "http://www.imsglobal.org/xsd/imsbasiclti_v1p0"
  def self.process(url)
    xml = url_to_xml(url)
    xml_to_hash(xml)
  end
  
  def self.url_to_xml(url)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    request = Net::HTTP::Get.new(uri.request_uri)
    response = nil
    begin
      response = http.request(request)
    rescue Timeout::Error => e
      raise LtiParseError.new("Request timed out")
    end
    if response.code.to_s.match(/^3/)
      raise LtiParseError.new("Parser doesn't handle redirects")
    end
    xml = Nokogiri::XML(response.body)
    raise LtiParseError.new("Invalid configuration") unless xml.css('cartridge_basiclti_link').length > 0
    return xml
  end

  def self.get_blti_namespace(doc)
    doc.namespaces.each_pair do |key, val|
      if val == BLTI_NAMESPACE
        return key.gsub('xmlns:','')
      end
    end
    "blti"
  end
  
  def self.get_custom_properties(node)
    props = {}
    node.children.each do |property|
      next if property.name == 'text'
      if property.name == 'property'
        props[property['name']] = property.text
      elsif property.name == 'options'
        props[property['name']] = get_custom_properties(property)
      elsif property.name == 'custom'
        props[:custom_fields] = get_custom_properties(property)
      end
    end
    props
  end
    
  def self.get_node_val(node, selector, default=nil)
    node.at_css(selector) ? node.at_css(selector).text : default
  end
  
  def self.xml_to_hash(doc)
    blti = get_blti_namespace(doc)
    link_css_path = "cartridge_basiclti_link"
    tool = {}
    tool[:description] = get_node_val(doc, "#{link_css_path} > #{blti}|description")
    tool[:title] = get_node_val(doc, "#{link_css_path} > #{blti}|title")
    tool[:url] = get_node_val(doc, "#{link_css_path} > #{blti}|secure_launch_url")
    tool[:url] ||= get_node_val(doc, "#{link_css_path} > #{blti}|launch_url")
    if !tool[:title]
      raise LtiParseError.new("Couldn't find title attribute")
    end
    if custom_node = doc.css("#{link_css_path} > #{blti}|custom").first
      tool[:custom_fields] = get_custom_properties(custom_node)
    end
    tool[:custom_fields] ||= {}

    doc.css("#{link_css_path} > #{blti}|extensions").each do |extension|
      tool[:extensions] ||= []
      ext = {}
      ext[:platform] = extension['platform']
      ext[:custom_fields] = get_custom_properties(extension)
      
      if ext[:platform] == CANVAS_PLATFORM
        tool[:privacy_level] = ext[:custom_fields].delete 'privacy_level'
        tool[:domain] = ext[:custom_fields].delete 'domain'
        tool[:consumer_key] = ext[:custom_fields].delete 'consumer_key'
        tool[:shared_secret] = ext[:custom_fields].delete 'shared_secret'
        tool[:tool_id] = ext[:custom_fields].delete 'tool_id'
        if tool[:assignment_points_possible] = ext[:custom_fields].delete('outcome')
          tool[:assignment_points_possible] = tool[:assignment_points_possible].to_f
        end
        tool[:settings] = ext[:custom_fields]
      else
        tool[:extensions] << ext
      end
    end
    if icon = get_node_val(doc, "#{link_css_path} > #{blti}|icon")
      tool[:settings] ||= {}
      tool[:settings][:icon_url] = icon
    end
    tool
  end
end

module XmlConfigParser
  def self.config_options(hash, params, host)
    result = {}
    hash['config_options'] ||= []
    opts = {}
    hash['config_options'].each{|o| opts[o['name']] = o}
    hash['options'] = opts
    
    hash['extensions'] ||= []
    result['name'] = sub(hash['variable_name'] || hash['name'], hash, params)
    result['description'] = sub(hash['variable_description'] || hash['short_description'] || hash['description'].split(/<br\/>/)[0] || "", hash, params)
    result['privacy_level'] = hash['privacy_level'] || 'anonymous'
    result['id'] = hash['id']
    
    # "Open launch" is syntactic sugar for a bunch of defaults
    if hash['app_type'] == 'open_launch'
      set_open_launch_options!(result, hash, host)
    # ...so is "Data launch"
    elsif hash['app_type'] == 'data'
      set_data_launch_options!(result, hash, host)
    # Otherwise we have to check a bunch of options
    else
      result['icon_url'] = hash['icon_url'] || (host + "/tools/#{result['id']}/icon.png")
      result['launch_url'] = prepend_host(sub(hash['launch_url'], hash, params), host) if hash['launch_url']
      result['domain'] = hash['domain'] if hash['domain']
      if hash['custom_fields']
        result['custom_fields'] = hash['custom_fields']
        result['custom_fields'].each do |key, val|
          result['custom_fields'][key] = sub(val, hash, params)
        end
      end
      if hash['extensions'].include?('course_nav')
        if !hash['options']['course_nav'] || params['course_nav'] == '1'
          result['course_navigation'] = {
            'launch_url' => prepend_host(sub(hash['course_nav_launch_url'] || hash['launch_url'], hash, params), host),
            'link_text' => sub(non_empty_or_default('course_nav_link_text', hash, params, result['name']), hash, params),
            'visibility' => non_empty_or_default('course_nav_visibility', hash, params),
            'default' => non_empty_or_default('course_nav_default', hash, params)
          }
        end
      end
      if hash['extensions'].include?('user_nav')
        if !hash['options']['user_nav'] || params['user_nav'] == '1'
          result['user_navigation'] = {
            'launch_url' => prepend_host(sub(hash['user_nav_launch_url'] || hash['launch_url'], hash, params), host),
            'link_text' => sub(non_empty_or_default('user_nav_link_text', hash, params, result['name']), hash, params)
          }
        end
      end
      if hash['extensions'].include?('account_nav')
        if !hash['options']['account_nav'] || params['account_nav'] == '1'
          result['account_navigation'] = {
            'launch_url' => prepend_host(sub(hash['account_nav_launch_url'] || hash['launch_url'], hash, params), host),
            'link_text' => sub(non_empty_or_default('account_nav_link_text', hash, params, result['name']), hash, params)
          }
        end
      end
      if hash['extensions'].include?('editor_button')
        if !hash['options']['editor_button'] || params['editor_button'] == '1'
          result['editor_button'] = {
            'launch_url' => prepend_host(sub(hash['editor_button_launch_url'] || hash['launch_url'], hash, params), host),
            'link_text' => sub(non_empty_or_default('editor_button_link_text', hash, params, result['name']), hash, params),
            'icon_url' => hash['editor_button_icon_url'] || result['icon_url'],
            'width' => hash['editor_button_width'] || hash['width'],
            'height' => hash['editor_button_height'] || hash['height']
          }
        end
      end
      if hash['extensions'].include?('resource_selection')
        if !hash['options']['resource_selection'] || params['resource_selection'] == '1'
          result['resource_selection'] = {
            'launch_url' => prepend_host(sub(hash['resource_selection_launch_url'] || hash['launch_url'], hash, params), host),
            'link_text' => sub(non_empty_or_default('resource_selection_link_text', hash, params, result['name']), hash, params),
            'icon_url' => hash['resource_selection_icon_url'] || result['icon_url'],
            'width' => hash['resource_selection_width'] || hash['width'],
            'height' => hash['resource_selection_height'] || hash['height']
          }
        end
      end
      if hash['extensions'].include?('homework_submission')
        if !hash['options']['homework_submission'] || params['homework_submission'] == '1'
          result['homework_submission'] = {
            'launch_url' => prepend_host(sub(hash['homework_submission_launch_url'] || hash['launch_url'], hash, params), host),
            'link_text' => sub(non_empty_or_default('homework_submission_link_text', hash, params, result['name']), hash, params),
            'icon_url' => hash['homework_submission_icon_url'] || result['icon_url'],
            'width' => hash['homework_submission_width'] || hash['width'],
            'height' => hash['homework_submission_height'] || hash['height']
          }
        end
      end
    end
    result
  end
  
  def self.set_data_launch_options!(result, hash, host)
    result['privacy_level'] = 'anonymous'
    result['launch_url'] = host + "/tool_redirect?id=#{result['id']}"
    result['icon_url'] = host + "/tools/#{result['id']}/icon.png"
    result['editor_button'] = {
      'launch_url' => result['launch_url'],
      'icon_url' => result['icon_url'],
      'width' => hash['width'] || 690,
      'height' => hash['height'] || 530,
      'link_text' => hash['name']
    }
    result['resource_selection'] = {
      'launch_url' => result['launch_url'],
      'icon_url' => result['icon_url'],
      'width' => hash['width'] || 690,
      'height' => hash['height'] || 530,
      'link_text' => hash['name']
    }
    result['launch_url'] = nil if hash['no_launch']
  end
  
  def self.set_open_launch_options!(result, hash, host)
    result['privacy_level'] = 'anonymous'
    result['launch_url'] = host + "/tool_redirect?id=#{result['id']}"
    result['icon_url'] = host + "/tools/#{result['id']}/icon.png"
    if hash['extensions'].include?('editor_button')
      result['editor_button'] = {
        'launch_url' => result['launch_url'],
        'icon_url' => result['icon_url'],
        'width' => hash['width'] || 690,
        'height' => hash['height'] || 530,
        'link_text' => hash['name']
      }
    end
    if hash['extensions'].include?('resource_selection')
      result['resource_selection'] = {
        'launch_url' => result['launch_url'],
        'icon_url' => result['icon_url'],
        'width' => hash['width'] || 690,
        'height' => hash['height'] || 530,
       'link_text' => hash['name']
      }
    end
  end
  
  def self.non_empty_or_default(key, hash, params, fallback=nil)
    res = params[key] if params[key] && params[key].length > 0 && hash['options'][key]
    res ||= hash['options'][key] && hash['options'][key]['value']
    res ||= hash[key]
    res ||= fallback
    res
  end
  
  def self.sub(string, hash, params)
    opts = hash['options']
    res = (string || '').gsub(/{{\s*escape:([\w_]+)\s*}}/){|w| CGI.escape(params[$1] || (opts[$1] && opts[$1]['value']) || '') }
    res.gsub(/{{\s*([\w_]+)\s*}}/){|w| params[$1] || (opts[$1] && opts[$1]['value']) || '' }
  end
  
  def self.prepend_host(url, host)
    if url.match(/^\//)
      host + url
    else
      url
    end
  end
end

module AppParser
  CATEGORIES = ["Assessment", "Community", "Completely Free", "Content", "Math", "Media", "Open Content", "Science", "Study Helps", "Textbooks/eBooks", "Web 2.0"]
  LEVELS = ["K-6th Grade", "7th-12th Grade", "Postsecondary"]
  EXTENSIONS = ["course_nav", "user_nav", "account_nav", "editor_button", "resource_selection", "homework_submission"]
  PRIVACY_LEVELS = ["public", "name_only", "email_only", "anonymous"]
  APP_TYPES = ["open_launch", "data"]
  
  def self.parse(params)
    hash = {}
    hash['name'] = params['name']
    hash['id'] = params['id']
    hash['categories'] = parse_categories(params)
    hash['levels'] = parse_levels(params)
    hash['doesnt_work'] = parse_ids(params['doesnt_work'])
    hash['only_works'] = parse_ids(params['only_works'])
    hash['description'] = fix_description(params['description'])
    hash['app_type'] = parse_app_type(params['app_type'])
    hash['short_description'] = unless_empty(params['short_description'])
    hash['extensions'] = parse_extensions(params)
    hash['preview'] = parse_preview(params)
    hash['beta'] = params['beta'] == '1' || params['beta'] == true
    hash['test_instructions'] = params['test_instructions']
    hash['support_link'] = params['support_link']
    hash['ims_link'] = params['ims_link']
    hash['author_name'] = params['author_name']
    hash['submitter_name'] = params['submitter_name']
    hash['submitter_url'] = params['submitter_url']
    hash['privacy_level'] = parse_privacy_level(params['privacy_level'])
    
    if hash['app_type'] == 'open_launch'
      hash['no_launch'] = unless_empty(params['no_launch'] == '1' || params['no_launch'] == true)
    elsif hash['app_type'] == 'data'
      hash['data_url'] = unless_empty(params['data_url'])
      hash['data_json'] = parse_data_json(params['data_json'])
    end
    
    if hash['app_type'] != 'open_launch'
      hash['icon_url'] = unless_empty(params['icon_url'])
      hash['logo_url'] = unless_empty(params['logo_url'])
      hash['banner_url'] = unless_empty(params['banner_url'])
    end
    
    if hash['app_type'] == 'open_launch' || hash['app_type'] == 'data'
      hash['exclude_from_public_collections'] = unless_empty(params['exclude_from_public_collections'] == '1' || params['exclude_from_public_collections'] == true)
    else
      hash['config_url'] = unless_empty(params['config_url'])
      hash['config_urls'] = parse_config_urls(params)
      hash['any_key'] = unless_empty(params['any_key'] == '1' || params['any_key'] == true)
    
      if hash['app_type'] == 'custom'
        hash['config_url'] = unless_empty(params['config_url'])
      else
        hash['launch_url'] = unless_empty(params['launch_url'])
        hash['domain'] = unless_empty(params['domain'])
        hash['config_directions'] = unless_empty(params['config_directions'])
        hash['custom_fields'] = parse_custom_fields(params)
        if hash['extensions'] && hash['extensions'].include?('course_nav')
          hash['course_nav_link_text'] = unless_empty(params['course_nav_link_text'])
        end
        if hash['extensions'] && hash['extensions'].include?('user_nav')
          hash['user_nav_link_text'] = unless_empty(params['user_nav_link_text'])
        end
        if hash['extensions'] && hash['extensions'].include?('account_nav')
          hash['account_nav_link_text'] = unless_empty(params['account_nav_link_text'])
        end
      end
    end
    hash['config_options'] = parse_config_options(params)
    if hash['config_options']
      hash['variable_name'] = unless_empty(params['variable_name'])
      hash['variable_description'] = unless_empty(params['variable_description'])
    end
    if hash['extensions'] && (hash['extensions'].include?('editor_button') || hash['extensions'].include?('resource_selection')) && params['app_type'] != 'custom'
      hash['width'] = unless_zero(params['width'])
      hash['height'] = unless_zero(params['height'])
    end
    
    hash.each do |key, val|
      hash.delete(key) if val == nil
    end
    hash
  end
  
  def self.fix_description(str)
    str ||= "No description"
    # xml parsers get mad if there's invalid entity refs
    str.gsub(/\&(?!\w+;)/, "&amp;")
    str
  end
  
  def self.parse_data_json(str)
    res = JSON.parse(str) rescue nil
    res = nil if res && !res.is_a?(Array)
    res = nil if res && (res.length > 500 || res.length == 0)
    (res || []).each do |record|
      res = nil if !record.is_a?(Hash) || !record['url'] || !record['name']
      break if res == nil
    end
    res && JSON.pretty_generate(res)
  end
  
  def self.unless_zero(str)
    res = str.to_i
    res = nil if res == 0
    res
  end
  
  def self.unless_empty(str)
    if str && (str == true || str.length > 0)
      str
    else 
      nil
    end
  end
  
  def self.parse_preview(params)
    if params['preview'] && params['preview']['url'] && params['preview']['url'].length > 0 && unless_zero(params['preview']['height'])
      {
        'url' => params['preview']['url'],
        'height' => unless_zero(params['preview']['height'])
      }
    else
      nil
    end
  end
  
  def self.parse_config_options(params)
    if params['config_options'].is_a?(Hash) && params['config_options'].to_a.all?{|f| f[0].to_i > 0 }
      list = []
      params['config_options'].each do |key, args|
        list << args
      end
      params['config_options'] = list
    end
    if params['config_options'].is_a?(Array)
      list = []
      params['config_options'].each do |obj|
        res = {
          'name' => obj['name'].to_s,
          'description' => obj['description'].to_s,
          'type' => obj['type'].to_s,
          'value' => obj['value'].to_s
        }
        res['required'] = true if obj['required'] == '1' || obj['required'] == true
        list << res
      end
      list
    else
      nil
    end
  end
  
  def self.parse_config_urls(params)
    if params['config_urls'].is_a?(Hash) && params['config_urls'].to_a.all?{|f| f[0].to_i > 0 }
      list = []
      params['config_urls'].each do |key, args|
        list << args
      end
      params['config_urls'] = list
    end
    if params['config_urls'].is_a?(Array)
      list = []
      params['config_urls'].each do |obj|
        list << {
          'url' => obj['url'].to_s,
          'description' => obj['description'].to_s
        }
      end
      list
    else
      nil
    end
  end
  
  def self.parse_custom_fields(params)
    res = nil
    if params['custom_fields'].is_a?(Hash) && params['custom_fields'].to_a.all?{|f| f[0].to_i > 0 }
      hash = {}
      params['custom_fields'].each do |key, args|
        hash[args['key']] = args['value']
      end
      params['custom_fields'] = hash
    end
    if params['custom_fields'].is_a?(Hash)
      params['custom_fields'].each do |key, val|
        res ||= {}
        res[key] = val.to_s
      end
    end
    res
  end
  
  def self.parse_app_type(str)
    (APP_TYPES + ['custom']).include?(str) ? str : nil
  end
  
  def self.parse_privacy_level(str)
    PRIVACY_LEVELS.include?(str) ? str : 'anonymous'
  end
  
  def self.parse_ids(ids)
    if ids.is_a?(String)
      ids = ids.split(/,/)
    end
    res = ids.is_a?(Array) ? ids.flatten.map(&:to_s) : nil
    res = nil if res && res.empty?
    res
  end
  
  def self.parse_categories(params)
    (params['categories']) & CATEGORIES
  end
  
  def self.parse_extensions(params)
    res = (params['extensions'] || []) & EXTENSIONS
    res = nil if res.empty?
    res
  end
  
  def self.parse_levels(params)
    (params['levels'] || []) & LEVELS
  end
end

module Hasher
  def self.diff(a, b)
    if a.is_a?(Hash) && b.is_a?(Hash)
      res = {}
      a.keys.each do |key|
        if d = diff(a[key], b[key])
          res[key] = d
        end
      end
      b.keys.each do |key|
        if d = diff(a[key], b[key])
          res[key] = d
        end
      end
      res.empty? ? nil : res
    elsif a.is_a?(Array) && b.is_a?(Array)
      bads = []
      a.each_with_index do |val, idx|
        if d = diff(a[idx], b[idx])
          bads << d
        end
      end
      b.each_with_index do |val, idx|
        if d = diff(a[idx], b[idx])
          bads << d
        end
      end
      bads.empty? ? nil : bads
    else
      a.to_s == b.to_s ? nil : (a || b)
    end
  end
end

class LtiParseError < Exception
end