Crunch Accounting API gem
=========================

Basic implementation of some of the Crunch Accounting API


Installation
------------

$ sudo gem install crunchaccounting-api


Authentication
--------------

1) Initialise

````
crunch = CrunchAPI.new(
	consumer_key: "consumer_key",
	consumer_secret: "consumer_secret",
	auth_endpoint: "https://app.crunch.co.uk",
	api_endpoint: "https://api.crunch.co.uk",

	debug: true  # optional, shows full HTTP requests
)
````

2) OAuth authentication

````
url = crunch.get_auth_url
````

Send the user to the URL and get their verification code.

````
crunch.verify_token(oauth_code)

p crunch.oauth_token
p crunch.oauth_token_secret
````

^^ store these two values

We are now authenticated.  Next time you can pass the oauth token and secret, eg:

````
CrunchAPI.new(
  ....
	oauth_token: "oauth_token",
  oauth_token_secret: "oauth_token_secret",
)
````


Usage
-----

Read the code, should be fairly self-explanatory.
