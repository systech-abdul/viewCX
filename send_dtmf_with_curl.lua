local webhook_url = "https://seec.view360.cx/flow/surveyIVR"
local payload = '{"message": "Hello"}'

-- Execute the curl command
os.execute(string.format('curl -X POST -H "Content-Type: application/json" -d \'%s\' %s', payload, webhook_url))

