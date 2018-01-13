#!/usr/bin/env ruby

require 'oauth'
require 'json'
require 'base64'

VAT_RATE_DEFAULT = 20

class CrunchAPI
  attr_reader :oauth_token
  attr_reader :oauth_token_secret

  def initialize(params={})
    @vat_rate = VAT_RATE_DEFAULT

    params.each do |key, value|
      instance_variable_set("@" + key.to_s, value)
    end

    if @oauth_token and @oauth_token_secret
      initialise_consumer
    end
  end

  def initialise_consumer
    @consumer = get_consumer(@api_endpoint)

    @access_token = OAuth::AccessToken.from_hash(
      @consumer, {
        oauth_token: @oauth_token,
        oauth_token_secret: @oauth_token_secret
      }
    )
  end 

  def authenticated?
    @access_token ? true : false
  end

  def get_consumer(endpoint)
    consumer = OAuth::Consumer.new(
      @consumer_key,
      @consumer_secret,
      :scheme => :header,
      :site => endpoint,
      :request_token_path => "/crunch-core/oauth/request_token",
      :authorize_path => "/crunch-core/login/oauth-login.seam",
      :access_token_path => "/crunch-core/oauth/access_token"
    )

    @debug and consumer.http.set_debug_output($stdout)

    consumer
  end

  def get_auth_url
    @consumer = get_consumer(@auth_endpoint)

    request_token = @consumer.get_request_token(:oauth_callback => "")

    @request_token = request_token.token
    @request_secret = request_token.secret

    return request_token.authorize_url(:oauth_callback => "")
  end

  def verify_token(oauth_verifier)
    hash = { oauth_token: @request_token, oauth_token_secret: @request_secret }

    request_token = OAuth::RequestToken.from_hash(@consumer, hash)

    @access_token = request_token.get_access_token(:oauth_verifier => oauth_verifier)
    @oauth_token = @access_token.params[:oauth_token]
    @oauth_token_secret = @access_token.params[:oauth_token_secret]

    initialise_consumer

    true
  end

  def get(uri)
    !@consumer and @consumer = get_consumer(@api_endpoint)

    resp = @access_token.get(uri, { "Accept" => "application/json" } )

    JSON.parse(resp.body)
  end

  def post(uri, params={})
    !@consumer and @consumer = get_consumer(@api_endpoint)

    resp = @access_token.post(uri, params.to_json, { "Content-Type" => "application/json", "Accept" => "application/json" } )

    JSON.parse(resp.body)
  end

  def put(uri, params={})
    !@consumer and @consumer = get_consumer(@api_endpoint)

    resp = @access_token.put(uri, params.to_json, { "Content-Type" => "application/json", "Accept" => "application/json" } )
  end

  def delete(uri)
    !@consumer and @consumer = get_consumer(@api_endpoint)

    resp = @access_token.delete(uri, { "Accept" => "application/json" } )

    JSON.parse(resp.body)
  end

  def accounts(type: nil)
    if type
      return get("/rest/v2/accounts/#{type}")
    else
      @accounts = {}

      resp = get("/rest/v2/accounts")

      resp["bankAccounts"].each do |account|
        if !@accounts[account["account"]]
          @accounts[account["account"]] = account
        end
      end

      return resp
    end
  end

  def account_by_name(name)
    if @accounts
      return @accounts[name]
    end

    accounts
    account_by_name name
  end

  def client_payments
    get "/rest/v2/client_payments"
  end

  def add_client_payment(params={})
    post "/rest/v2/client_payments", params
  end

  def expense_types
    get "/rest/v2/expense_types"
  end

  def expenses
    resp = get "/rest/v2/expenses"

    @expenses = []

    resp["expense"].each do |expense|
      @expenses.push expense
    end

    @expenses
  end

  def suppliers
    resp = get "/rest/v2/suppliers"

    @suppliers = {}

    resp["supplier"].each do |supplier|
      if !@suppliers[supplier["name"]]
        @suppliers[supplier["name"]] = supplier
      end
    end

    @suppliers
  end

  def supplier_by_name(name)
    if @suppliers
      return @suppliers[name]
    end

    suppliers

    supplier_by_name(name)
  end

  def delete_supplier(supplier_id)
    delete "/rest/v2/suppliers/#{supplier_id}"
  end

  def subject_to_vat?(expense_type)
    if [
        "GENERAL_INSURANCE",
        "MILEAGE_ALLOWANCE",
        "MEDICAL_INSURANCE_CONTRIBUTIONS",
        "BANK_CHARGES",
        "PENSION_SCHEME_CONTRIBUTIONS",
        "PUBLIC_TRANSPORT"
      ].include? expense_type
      return false
    end

    if [
      "ACCOUNTANCY",
      "CHILDCARE_VOUCHER_ADMIN_FEES",
      "WEB_HOSTING_CLOUD_SERVICES"
    ].include? expense_type
      return true
    end

    raise "Don't know if #{expense_type} is subject to VAT"
  end

  def add_expense(supplier_id:, date:, payment_date:, payment_method: nil, bank_account_id:, amount:, expense_type:, description:, director_id:nil, invoice:nil)
    !payment_method and payment_method = "EFT"

    if subject_to_vat?(expense_type)
      gross_amount = amount
      vat_amount = ((amount / 100) * @vat_rate).round(2)
      net_amount = (amount - vat_amount).round(2)
    else
      gross_amount = amount
      vat_amount = 0
      net_amount = amount
    end

    expense = {
      "amount" => amount,
      "expenseDetails" => {
        "supplier" => {
          "supplierId" => supplier_id
        },
        "postingDate" => date
      },
      "paymentDetails" => {
        "payment" => [{
          "paymentDate" => payment_date,
          "paymentMethod" => payment_method,
          "bankAccount" => {
            "accountId" => bank_account_id
          },
          "amount" => amount
        }]
      },
      "expenseLineItems" => {
        "count": 1,
        "lineItemGrossTotal": gross_amount,
        "expenseLineItems" => [
          {
            "expenseType" => expense_type,
            "benefitingDirector": director_id,
            "lineItemDescription" => description,
            "lineItemAmount" => {
              "currencyCode": "GBP",
              "netAmount" => net_amount,
              "grossAmount" => gross_amount,
              "vatAmount" => vat_amount
            }
          }
        ]
      }
    }

    if invoice and invoice != "NONE"
      mimetype = file_mimetype(invoice)
      filename = invoice.split("/").last

      expense["receipts"] = {
        "count" => 1,
        "receipt" => [
          {
            "fileName" => filename,
            "contentType" => mimetype,
            "fileData": Base64.encode64(File.read(invoice))
          }
        ]
      }
    end

    post "/rest/v2/expenses", expense
  end

  def update_expense(expense_id:, supplier_id:, date:, payment_date:, payment_method: nil, bank_account_id:, amount:, expense_type:, description:, director_id:nil, invoice:nil)
    !payment_method and payment_method = "EFT"

    if subject_to_vat?(expense_type)
      gross_amount = amount
      vat_amount = ((amount / 100) * @vat_rate).round(2)
      net_amount = (amount - vat_amount).round(2)
    else
      gross_amount = amount
      vat_amount = 0
      net_amount = amount
    end

    expense = {
			"expenseId" => expense_id,
      "amount" => amount,
      "expenseDetails" => {
        "supplier" => {
          "supplierId" => supplier_id
        },
        "postingDate" => date
      },
      "paymentDetails" => {
        "payment" => [{
          "paymentDate" => payment_date,
          "paymentMethod" => payment_method,
          "bankAccount" => {
            "accountId" => bank_account_id
          },
          "amount" => amount
        }]
      },
      "expenseLineItems" => {
        "count": 1,
        "lineItemGrossTotal": gross_amount,
        "expenseLineItems" => [
          {
            "expenseType" => expense_type,
            "benefitingDirector": director_id,
            "lineItemDescription" => description,
            "lineItemAmount" => {
              "currencyCode": "GBP",
              "netAmount" => net_amount,
              "grossAmount" => gross_amount,
              "vatAmount" => vat_amount
            }
          }
        ]
      }
    }

    if invoice
      mimetype = file_mimetype(invoice)
      filename = invoice.split("/").last

      expense["receipts"] = {
        "count" => 1,
        "receipt" => [
          {
            "fileName" => filename,
            "contentType" => mimetype,
            "fileData": Base64.encode64(File.read(invoice))
          }
        ]
      }
    end

    put "/rest/v2/expenses", expense
  end

  def file_mimetype(filename)
    esc = Shellwords.escape(filename)
    `/usr/bin/file -bi #{esc}`.chomp.gsub(/;.*\z/, '')
  end

  def find_expense(supplier_id:, date:, payment_date:, payment_method: nil, bank_account_id:, amount:, expense_type:, ignore_ids:[])
    !payment_method and payment_method = "EFT"

    if !@expenses
      expenses
    end

    @expenses.each do |expense|
      if ignore_ids.include?(expense["expenseId"])
        next
      end

      if expense["expenseDetails"]["supplier"]["supplierId"] == supplier_id and
        expense["expenseDetails"]["postingDate"] == date and
        expense["paymentDetails"]["payment"][0]["paymentDate"] == payment_date and
        expense["paymentDetails"]["payment"][0]["paymentMethod"] == payment_method and
        expense["paymentDetails"]["payment"][0]["bankAccount"]["accountId"] == bank_account_id and
        expense["paymentDetails"]["payment"][0]["amount"] == amount and
        expense["expenseLineItems"]["expenseLineItems"][0]["expenseType"] == expense_type

        return expense
      end
    end

    false
  end

  def clients
    get "/rest/v2/clients"
  end

  def find_client(name)
    clients["client"].each do |client|
      if client["name"] == name
        return client
      end
    end

    false
  end

  def invoices
    get "/rest/v2/sales_invoices"
  end

  def find_outstanding_client_invoice(client_id, amount)
    invoices["salesInvoice"].each do |invoice|
      total = 0

      invoice["salesInvoiceLineItems"]["salesInvoiceLineItem"].each do |item|
        total += item["lineItemAmount"]["grossAmount"]
      end

      if invoice["salesInvoiceDetails"]["client"]["clientId"] == client_id and
        total == amount and
        invoice["salesInvoiceDetails"]["state"] != "SETTLED"

        return invoice
      end
    end

    false
  end

  def find_draft_invoice(client_id, date)
    invoices["salesInvoice"].each do |invoice|
      if invoice["salesInvoiceDetails"]["client"]["clientId"] == client_id and
        invoice["salesInvoiceDetails"]["issuedDate"] == date and
        invoice["salesInvoiceDetails"]["state"] == "DRAFT"

        return invoice
      end
    end

    false
  end

  def find_invoice(client_id, date)
    invoices["salesInvoice"].each do |invoice|
      if invoice["salesInvoiceDetails"]["client"]["clientId"] == client_id and
        invoice["salesInvoiceDetails"]["issuedDate"] == date

        return invoice
      end
    end

    false
  end

  def issue_invoice(invoice)
    put "/rest/v2/sales_invoices/#{invoice["salesInvoiceId"]}/issue"
  end

  def find_client_payment(client_id:, date:, payment_method: nil, bank_account_id:, amount:, invoice_id:)
    !payment_method and payment_method = "EFT"

    client_payments.each do |client_payment|
      if client_payment["paymentDate"] == date and
        client_payment["paymentMethod"] == payment_method and
        client_payment["bankAccount"]["accountId"] == bank_account_id and
        client_payment["amount"] == amount and
        client_payment["client"]["clientId"] == client_id and
        client_payment["salesInvoices"]["salesInvoice"][0]["salesInvoiceId"] == invoice_id

        return client_payment
      end
    end

    false
  end

  def add_client_payment(client_id:, date:, payment_method: nil, bank_account_id:, amount:, invoice_id:)
    !payment_method and payment_method = "EFT"

    payment = {
      "paymentDate" => date,
      "paymentMethod" => payment_method,
      "bankAccount" => {
        "accountId" => bank_account_id,
      },
      "amount" => amount,
      "currency" => "GBP",
      "client" => {
        "clientId" => client_id,
      },
      "salesInvoices" => {
        "salesInvoice" => [
          {
            "salesInvoiceId" => invoice_id,
            "allocatedAmount" => amount,
          }
        ]
      }
    }

    post "/rest/v2/client_payments", payment
  end

  def get_next_client_ref_for_client(client)
    abbr = ""

    for i in 0...client.length
      if client["name"][i].match(/[A-Z]/)
        abbr += client["name"][i]
      end
    end

    used = []

    invoices["salesInvoice"].each do |invoice|
      if invoice["salesInvoiceDetails"]["client"]["clientId"] == client["clientId"]
        used.push invoice["salesInvoiceDetails"]["clientReference"]
      end
    end

    n = 1
    ref = "#{abbr}#{n.to_s.rjust(3,'0')}"

    while used.include? ref
      n += 1
      ref = "#{abbr}#{n.to_s.rjust(3,'0')}"
    end

    ref
  end

  def raise_invoice(client_id:,date:,client_ref:nil,description:,rate:,quantity:,add_vat:true)
    amount = rate * quantity

    if add_vat
      vat = ((amount / 100) * @vat_rate).round(2)
      vat_type = "STANDARD"
    else
      vat = 0
      vat_type = "OUTSIDE_SCOPE"
    end

    client = get "/rest/v2/clients/#{client_id}"

    if !client_ref
      client_ref = get_next_client_ref_for_client(client)
    end

    invoice = {
      "currency" => "GBP",
      "salesInvoiceLineItems" => {
        "salesInvoiceLineItem" => [
          {
            "lineItemDescription" => description,
            "quantity" => quantity,
            "rate" => rate,
            "lineItemAmount" => {
              "netAmount" => amount,
              "grossAmount" => amount + vat,
              "vatAmount" => vat,
              "vatRate" => @vat_rate
            },
            "vatType" => vat_type
          },
        ],
        "count" => 1
      },
      "salesInvoiceDetails" => {
        "client" => {
          "clientId" => client_id,
        },
        "clientReference" => client_ref,
        "issuedDate" => date,
        "paymentTermsDays" => client["paymentTermsDays"],
      }
    }

    post "/rest/v2/sales_invoices", invoice
  end
end
