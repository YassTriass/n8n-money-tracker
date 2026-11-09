# Starts n8n in the background at Windows logon (registered in Task Scheduler).
# Prefer IPv4 for DNS lookups: fixes intermittent timeouts to Google APIs.
$env:NODE_OPTIONS = "--dns-result-order=ipv4first"
# Keep schedules (monthly report on the 2nd) and dates in local time.
$env:GENERIC_TIMEZONE = "Asia/Jakarta"
$env:TZ = "Asia/Jakarta"

# n8n installed globally with: npm install -g n8n
& "$env:APPDATA\npm\n8n.cmd" start