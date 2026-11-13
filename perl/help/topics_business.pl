# Help registry part 4 of 9: Store, crypto, pay, warehouse, market and inventory.
package help;

use strict;
our %topic;

$topic{'store'} = {
		title => 'Store', category => 'apps', app => 'store',
		verified => '2026-11-13',
		templates => [ 'templates/store/store.html.ep', 'templates/store/category.html.ep', 'templates/store/item.html.ep', 'templates/store/item_selection.html.ep', 'templates/store/list.html.ep', 'templates/store/register.html.ep', 'templates/store/journal.html.ep', 'templates/store/correspondence.html.ep', 'templates/store/customer.html.ep', 'templates/ribbons.html.ep', 'templates/store/printer/header.html.ep', 'public/css/store.css', 'public/js/store.js', 'public/js/store/register.js' ],
		summary => 'Items, models, options, quotes, invoices and a cash register.',
		body => [
			'Store is the catalogue and the paperwork. Items carry models and options, each with its own prices; a quote or invoice is built from them and prints to a white, house-styled sheet that can be delivered by email.',
			'Browsing is arranged as shelves: the category rail on the left shows only categories that hold something, with the number of items beside each, and choosing one fills the item grid. The subcategory chips under the rail narrow that shelf, the type chips at the top filter by product, service, event, place or media, and the sort control orders by name or price. Search runs across the whole store once two characters are typed. The result count says how many items the filters leave; Clear puts every filter back.',
			'Choosing an item opens its details in a pane beside the grid rather than over it, so the shelves stay in view; Back to items (or the close button) returns to them. The price summary stays pinned to the foot of that pane while the models and options scroll, and it can be tapped to edit a price.',
			'With a customer loaded, the foot of the window carries four labelled actions. Quotes and Invoices list the documents themselves. Register is the customer\'s sales journal: every invoice or sale for that customer with its total, amount paid and balance, and each payment indented beneath the document it settled. Correspondence is the other journal: the emails and chats the house and that customer exchanged, newest first, showing the channel, direction, subject and a readable preview.',
			'Register in the toolbar is the cash till, and it is always available: a person who is not in the customer list is simply Customer. With no customer loaded, the bar at the foot of the window also offers Register, so a walk-in can be served without searching for a name; once a customer is loaded it steps aside for that customer\'s four actions. Choosing items from its search adds them to the open order, the quantity buttons change how many, and the line can be removed. Several customers can stand at the counter at once: each order is its own tab with its own total, New order starts another, and Void gives one up without recording a sale or disturbing the others. The payment method is Cash, Credit, Interac, Bitcoin or Cheque; Cash offers $5, $10, $20, $50 and $100 buttons (and coins) that add what was handed over, shows the change to give back and the notes and coins that make it. Complete sale writes the sale, prints a receipt, and leaves a Receipt button to open it again. A card or other method is charged the total; a cash payment that does not cover the total is refused rather than recorded short.',
			'The Print button opens the sheet with a printer bar. A default printer chosen in Dev prints at once; with no default the bar asks which CUPS queue, and Save to PDF makes the same sheet as a file. The register\'s Receipt button uses the same bar.',
			'The movement dropdown uses the house\'s own words: Selling (an income movement) is what this house has available, and Buying (an expense movement) is a purchase the house makes. The stored movement values are unchanged, so existing quotes, invoices and reports keep working.',
			'Recording a payment against a document updates its balance and closes it when the balance reaches zero. A document row also carries a wallet icon when the house has a crypto wallet: it opens the crypto payment panel, which shows the coin, the amount for the balance, the invoice\'s own receiving address and a QR (see Crypto wallets and rates).',
			'A visitor who asks for a ticket sees the privacy notice before the form and must acknowledge it; the acknowledgement is stored with the request. The standalone storefront and the public homepage both link to the full privacy policy at the foot of the page; a Store opened in a desk window does not repeat it. The policy names the controller, the data processed, the legal basis, retention, the cookies and local storage used, and how to exercise a data right.'
		],
		steps => [
			'Open Store and add the items you sell, each with its models and options and their prices.',
			'Use the category rail and the type chips to narrow the shelves; search finds an item by name anywhere in the store.',
			'Build a quote from those items and options; the totals are worked out as you go.',
			'When the quote is accepted, move it to an invoice — it converts and the quote is consumed.',
			'Email the invoice to the customer, or print it to the house-styled sheet.',
			'Press Print on a quote or invoice (or Receipt in the register) to print to the default CUPS printer, choose another, or save the sheet as a PDF.',
			'For a walk-in sale, open Register in the toolbar (or in the customer bar when no one is loaded), search for an item, add it and set the quantity. Choose the payment method, press the cash buttons for what the customer handed over, check the change, then press Complete sale and hand over the receipt.',
			'Record a payment against it; the balance falls and it closes at zero.'
		],
		related => [ 'budget', 'invoices_payments', 'market', 'crypto' ]
	};
$topic{'crypto'} = {
		title => 'Crypto wallets and rates', category => 'functions',
		verified => '2026-10-30',
		templates => [ 'templates/configure/pay_setting_list.html.ep', 'templates/configure/crypto_setting_list.html.ep', 'templates/configure/appointment_list.html.ep', 'templates/store/crypto_payment.html.ep', 'templates/store/printer/header.html.ep', 'templates/store/pay_box.html.ep', 'templates/store/list.html.ep', 'public/js/manager/configure.js', 'public/js/manager/transaction.js', 'public/js/store.js' ],
		summary => 'Wallet accounts that hold a coin, per-invoice receiving addresses from an xpub, live fiat and coin rates, and cost or market valuation.',
		body => [
			'A wallet is an ordinary account whose Payment Type is crypto. It keeps a public address and the coin it holds, and it records transactions, transfers and statements like any other account. JawnOS never holds a key, cannot spend from a wallet, and refuses anything that looks like a seed phrase or a private key; if a page ever asks for one, it is not JawnOS.',
			'A hardware wallet is the right home for coins you are not about to spend: the device keeps the key, and JawnOS only ever sees the public address. For the widest coin coverage, Ledger Nano S Plus or Flex; for open-source firmware, Trezor Safe 3/5 or BitBox02; if it is Bitcoin only, Coldcard or Blockstream Jade. Buy direct from the maker, never a reseller or a marketplace, and never trust a device that arrives already set up. Write the recovery phrase on paper or steel, keep it offline, and never type it into a computer or a website. Review this recommendation every three to six months, and update the device firmware in the same pass: devices, prices and coin support move.',
			'A wallet can issue a fresh receiving address for every invoice. In Configure -> App, paste the Bitcoin account xpub (xpub, ypub or zpub) into Account xpub; it is public, so it can derive addresses and cannot spend. The invoice then owns its own address: the first time it is written, and again when it is opened for payment or saved after the key was added, JawnOS derives the next unused address at /0/index and keeps it with the invoice. A wallet with no xpub keeps the single saved address. If the wallet\'s own app does not show an xpub (Ledger Live does not), connect the device to Sparrow or Electrum on the laptop and copy the account xpub from there. Compare the first five addresses with the wallet app\'s Receive list; if they do not match, the path or script type is wrong, so clear the key and check the wallet. Only Bitcoin is supported for this so far.',
			'A crypto payment cannot be reversed or refused by this server. The QR on an invoice carries the exact amount, and the invoice panel refuses to record a payment once the balance is zero, so the ledger cannot count a second payment twice. Coins sent a second time still arrive, though: the wallet shows them, and the payment panel reports an overpayment so the seller can return the extra deliberately.',
			'Configure -> Plat -> Pay -> Crypto owns the shared parts: which coins may be used, the cached exchange rates, and how a holding is valued. Cost is the money recorded when the coin arrived, which is the safe figure for statements. Market is the native holding at today\'s rate, which moves with the price. The wallet list shows both so the difference is visible.',
			'Every conversion in the app now reads the same rate snapshot, including a measure typed as 5USD to CAD or 0.01BTC to CAD. One public, keyless call to Coinbase returns every fiat code and every coin; the snapshot keeps the most-used fiat currencies (the top 50 the source answers) and the enabled coins. A half-hour loop refreshes it, and Refresh now asks at once. While no snapshot has been read, the older built-in constants still answer. An offline house keeps its last snapshot rather than losing its rates.',
			'Currency tracking keeps a history without an appointment. Tick it and every six hours one measure appointment is written into the app chosen under History app - Canadian Dollar by default, since that is the app this house already used, or Markets if you prefer - with a value for every tracked fiat code. The Measures app charts those points. Choosing a different History app while tracking is on writes the first point there at once. Stop the old app\'s own appointment once the tick is on, or both will write. The same snapshot also fills the Measures app\'s PV column: every currency row, plus a row for each enabled coin, shows one unit valued in the reporting currency.',
			'In a transaction, a wallet account is read in its own coin: type the native amount and the form shows what it is worth, while the ledger stores the house\'s reporting-currency value so every budget and statement still sums one currency. A transfer between two wallets must stay in the same coin on both sides; moving between a wallet and a bank is a sale and a purchase, not a transfer, and the app will say so rather than write a wrong figure.',
			'An invoice in the Store carries a crypto action when a wallet exists. It shows the coin, the amount for the balance, the invoice\'s own receiving address and a QR. The printed or on-screen invoice carries one QR: a BIP21 payment request (bitcoin:address?amount=...) when it is a single unpaid invoice with a Bitcoin wallet, and the public invoice link otherwise. After the buyer sends the coin, type the amount and txid and press Verify & record. A payer\'s PAY1Z proof, when pasted, is checked against their crest and countersigned with this house\'s; the txid is carried, not checked against the chain. On a device with a fingerprint the record asks for it; a device without one (a laptop, or a tablet with only a PIN) asks another fingerprinted device in the house. Only when the house has no fingerprinted device does the signed-in citizen record it.',
			'The coin list carries Bitcoin, Ethereum, USD Coin, Tether, Litecoin, Solana, Dogecoin, XRP, Cardano, BNB, TRON, Avalanche, Chainlink, Polkadot, Bitcoin Cash, Stellar, Cosmos and Toncoin. Only the ticked ones appear when a wallet or a payment picks a coin.',
			'To pay another house, open Configure -> Plat -> Pay -> Crypto -> Make a payment proof: paste the seller\'s crest uuid (their Store crypto panel shows it), the invoice ref, coin, amount, address and txid, then sign with this house\'s crest. Hand the PAY1Z code (or its QR) to the seller; their panel verifies it and countersigns the same bytes.',
		],
		steps => [
			'Open Configure -> Plat -> Pay and make sure the coins you want are ticked.',
			'Press Refresh now once; the rate table and the last-read time show what the house will use.',
			'In Configure -> App, make the account, turn on Payment Type, set it to crypto, then fill in the coin, network, public address and a label.',
			'Use a receive address from a hardware wallet you control, not an exchange deposit address; copy it into the wallet card, confirm it on the device screen, and send a small test amount before relying on it.',
			'For a fresh address on every invoice, paste the Bitcoin account xpub into Account xpub and compare the next invoice address it reports with the wallet app\'s Receive list. Bitcoin only, and never a private key or seed phrase.',
			'Record a transaction from that account in the app: the amount is in the coin, and the line beside it shows the money value before you save.',
			'Read the wallet list in Plat -> Pay -> Crypto for the holding, its cost and its market value; choose which one the rest of the page treats as the value.',
			'Tick Currency tracking if you want rate history: it writes a point every six hours into the selected History app (Canadian Dollar or Markets by default), and the Measures app charts it.',
			'Pick a different History app if the currency measures should live elsewhere; selecting one while tracking is on writes the first point there straight away.',
			'To take a crypto payment, open the customer\'s invoices in the Store, press the wallet icon on the invoice, send the shown amount to the address, then fill in the amount and txid (and paste the buyer\'s PAY1Z proof if they gave one) and press Verify & record.',
			'Print or open an unpaid invoice: its single QR is the exact-amount payment request. A second send cannot be stopped on the chain; the panel will not record it after the balance reaches zero, so return any excess from the wallet.',
			'To pay another house, build a PAY1Z proof under Configure -> Plat -> Pay -> Crypto -> Make a payment proof and give the seller the code; they verify and countersign it when they record the payment.',
			'Stop the currency app\'s old updating appointment once tracking is on, so the history has one writer.'
		],
		related => [ 'budget', 'store', 'configure' ]
	};
$topic{'pay'} = {
		title => 'Taking payment online', category => 'functions', verified => '2026-10-30',
		templates => [ 'templates/configure/pay_setting_list.html.ep', 'templates/configure/crypto_setting_list.html.ep', 'templates/store/pay_box.html.ep', 'templates/store/printer/header.html.ep', 'templates/pay/message.html.ep', 'templates/pay/return.html.ep', 'public/js/manager/configure.js' ],
		summary => 'Stripe, Square, PayPal and Interac e-Transfer on a public invoice, beside the crypto wallets they share a page with.',
		body => [
			'Configure -> Plat -> Pay is one page with Crypto as its first section and the hosted checkouts below it. The switch at the top turns every online method on or off; the currency is the house reporting currency, and the public address is what a provider redirects back to and what it posts a webhook to. Leave the address blank to use this house\'s public name on port 3000, or set it when a tunnel or proxy answers on another address.',
			'Stripe, Square and PayPal each create a hosted checkout for the exact invoice balance. The customer types card or PayPal details on the provider\'s page, never here, and returns to this house. The return page asks the provider what happened and records the payment; a webhook does the same when the house is reachable from the internet. Either path is safe to repeat: the provider reference is stored on the payment, so a return and a webhook cannot count the same money twice.',
			'Keys are sealed in the same way as an AI provider key. A secret field left blank keeps the saved value; type a new one to replace it, or press Clear. Test keys asks the provider a harmless question and reports whether it answered. Stripe needs the secret key and, for webhooks, the signing secret. Square needs the access token, a location id, the signature key, and the exact webhook URL Square shows if it differs from the one this page prints. PayPal needs the client id, the secret, and the webhook id.',
			'Every payment is booked as an ordinary income transaction on the account chosen for that provider, so a statement, budget or reconciliation sees it like any other money. Without a chosen account the first matching credit account is used, and Interac looks for an interac account first. The payment is also pushed onto the invoice, which falls by the amount and closes at zero. A partial payment leaves the invoice open for the rest.',
			'Interac e-Transfer has no consumer API, so JawnOS reads the notification letters that already arrive in the mailbox. English and French notices are both understood. With Autodeposit on, the money lands without a question and the invoice is matched by its reference, then by the exact amount, then by the sender. A notification is staged for a person unless Record automatically is ticked, and even then only when the money is already deposited and exactly one invoice carries the reference. Without Autodeposit the sender\'s security question has to be answered by a person; record the transfer after it has landed. A bank or payment service that can forward the same facts can POST amount, currency, sender, reference, memo, deposited and an optional invoice to the Forwarder URL, whose token is a password.',
			'An unpaid invoice\'s public page carries the pay buttons. A provider appears only when it is switched on and has its keys, so a half-finished panel never offers a button that cannot complete. The e-Transfer section prints the receiving address, the amount in the receiving account\'s own currency, and the invoice reference, and the invoice\'s QR still carries its public link. Nothing is charged until the customer confirms on the provider\'s page.',
			'JawnOS records the gross amount the provider reports. A provider fee, a refund or a chargeback is handled at the provider; refunding there and deleting the payment\'s income transaction here puts the invoice balance back and reopens it. Card data never touches this machine, and a webhook is only believed after its signature verifies against the key saved on this page.'
		],
		steps => [
			'Open Configure -> Plat -> Pay and tick Online payments.',
			'Set the public address if the house is reached through a tunnel or a name other than its own; otherwise leave it blank.',
			'For cards, open Stripe, paste the secret key and the webhook signing secret, choose the account the money books to, and press Test keys.',
			'For Square, paste the access token, choose Production or Sandbox, set the location id, paste the signature key, and press Test keys.',
			'For PayPal, paste the client id, secret and webhook id, choose the account, and press Test keys.',
			'Add the printed webhook URL at the provider (Stripe: checkout.session.completed and checkout.session.async_payment_succeeded; Square: payment.updated; PayPal: CHECKOUT.ORDER.APPROVED and PAYMENT.CAPTURE.COMPLETED).',
			'For e-Transfer, set the receiving email, tick Autodeposit when the address has it, choose the account, and tick Watch the inbox.',
			'Open an unpaid invoice\'s public page (the link in its QR or the emailed sheet) and press a pay button; finish on the provider\'s page and come back.',
			'Check the invoice: the payment is listed, the balance has fallen, and the income transaction is on the chosen account.',
			'For e-Transfer, open Pay after the notification arrives, choose the invoice if the match is ambiguous, and press Record; or tick Record automatically once the references are reliable.',
			'To refund, refund at the provider, then delete the payment\'s income transaction so the invoice reopens.',
			'For crypto wallets and rates, read the Crypto section on the same page; it behaves exactly as it did under Plat -> Crypto.'
		],
		related => [ 'crypto', 'store', 'invoices_payments', 'configure' ]
	};
$topic{'warehouse'} = {
		title => 'Warehouse', category => 'apps', app => 'warehouse',
		verified => '2026-10-30',
		summary => 'Money and goods tracked per place.',
		body => [
			'Warehouse tracks stock per place: what is where and how much of it. Packaging carries real quantities (a carton of twelve, a box of nails by weight), and shelf life means expired stock is swept up on its own.',
			'Stock is a physical ledger, not a claim on who paid. A purchase adds stock through its transaction; Stock in adds what arrived without one - a gift, something found, a transfer in - and carries no money. A sale, a consumption or an expiry takes stock out. Stock in takes the item and the amount together: 4260mL for a 12-pack of 355mL, or 12 each if you count packs.',
			'An app can move stock from its own quantity field. Set Stock Movement to Consume or Produce in the app\'s Configure, and set Stock Item if the warehouse name differs from the app\'s name. A Record moves at once; a Start/Stop session moves when it stops, using the amount typed at the start, so a cancelled session never touches the shelf. Only a real measure moves stock - a volume, a mass, a length or a count; hours and money are not stock.',
			'Consume takes only what is on the shelf at that place. Anything beyond it is recorded as Usage: the drink that came from outside the warehouse is counted in the moves ledger and the item\'s journal, but it does not make the shelf negative. When a pack is bought later, the purchase fills the shelf and the next consumption comes out of it; when that runs out, consumption goes back to Usage. That is how a daily Coke bought for you and a 12-pack you bought yourself live in one account.',
			'Every stock movement is journalled with its reason, and a moves ledger folds stock and money into one signed list.'
		],
		steps => [
			'Open Warehouse and set up the places you keep stock in.',
			'Add your products; where a product ships in packaging, give the packaging its real quantity.',
			'Use Stock in for what arrived without a purchase: a gift, something found, a transfer in.',
			'On an app whose amount you want counted, set Stock Movement to Consume (or Produce) and Stock Item if its warehouse name differs.',
			'Move stock in and out - each move is journalled with its reason.',
			'Read the moves ledger to see goods and money together; Usage rows are consumption that had no shelf to come from.'
		],
		related => [ 'inventory', 'market', 'moves_ledger' ]
	};
$topic{'market'} = {
		title => 'Market', category => 'apps', app => 'market',
		'verified' => '2026-10-30',
		templates => [ 'templates/market/market.html.ep', 'public/js/manager/market.js', 'public/js/manager/market/01_tabs_and_receipts.js' ],
		summary => 'The shopping list and the shopping run.',
		body => [
			'Market is where what you need to buy gathers. A Lists dropdown groups what to buy by kind, prepopulated with the house\'s categories (Clothes, Food, Household, Tech, and the rest) and opening the list you were last on; a Vendors dropdown scopes to a shop. The Shopping List tab holds what to buy, each row carrying a need/want dial, and Enter adds an item; the Shopping tab reads the same list through a Needs, Wants or All filter.',
			'An item the warehouse says is due - one whose own quantity budget (keep 6 on hand) sits below its target - is upgraded to a need on its own, so the shopping run already knows what is short.',
			'While you shop, tick an item off and drop it in the cart; Checkout retires the cart from the list and opens the list\'s category with an expense transaction filled line by line from the cart - quantity, unit and amounts are all editable there, and pressing Save is what records the purchases (each on the item\'s own app, and its stock move). The + beside Unit names a new packaging on the spot (a loaf, a bag of six) and offers it here and next time. Cancel just empties the cart back onto the list.',
			'Scan reads a barcode - the app\'s own bridge on a phone, else the camera, else a typed code. A code never seen before is looked up once and named in our terms by the model (a house item name, a category we keep, a unit), then remembered, so the same product is instant next time.',
			'Scan remembers the device it last used and starts there, so a phone chosen once is the default next time. That device opens its own scanner (the phone\'s Google code scanner) as if it had pressed Scan; each read comes back to the machine that started the run, and the scanner re-opens for the next one. On a computer with a webcam the machine reads with zbar straight from the camera instead - hold an item up and it appears on the scanning page in real time. The reads collect on the scanning page: Done puts them on the list, Cancel throws them away, and either one puts the phone\'s scan sheet away. The phone\'s Back button cancels too. The device picker stays on the scanning page, so another input can join the run (a phone beside the webcam) and each input has an x to stop just it. A browser without that scanner gets a live camera view instead, and a machine with no camera can type the code in the app.',
			'An account is an app whose part of speech is account (a Visa, a debit card, Cash). Its Configure panel carries a Payment type (cash, debit, credit, visa, mastercard, amex, interac, crypto, cheque, gift, other); a receipt whose tender says mastercard is matched to the account with that type, and the confirm lets you correct the pick. When no account names the word exactly, its family decides if that family has only one account: a receipt saying credit finds the only credit card (a mastercard, say), and debit or interac finds the only debit one.',
			'Receipt reads a whole shopping run at once, for the shop you did not scan at the till. The Receipt button offers the scanner (the ADF feeds the long receipt in one pass) or a photo - the scanner buttons appear only on a machine that has one; while the feeder runs the panel shows the scanner\'s own line and each page as it arrives, Cancel stops it, and a run that produces nothing says why (no paper, device busy). A receipt dropped in the printer\'s feeder is noticed by the house: a notice appears on the connected devices, and a Market window that is already open claims the scan on its own and opens the confirm when the pages are read. The vision model reads the pages into lines, and the confirm shows the receipt page full size beside them with the date, total, paid-by, reference and account editable, so they can be checked against the paper; each line is named in our terms and marked when it is already on the list. Add to cart links them into the list in the cart, so Checkout still writes the purchases, and the receipt itself - with its date, total and tender - is kept with the Market app.',
			'Receipts reopens what was kept. Once a receipt has been read, the Receipts button lists them newest first, each with its date, total and page thumbnails (press a page to open it); Add to list puts that receipt\'s lines back on the list in one press, the same way a fresh read does.',
			'Where you are decides which lists apply. A list remembers the vendors it is shopped at, and a vendor has a home plate; when Market opens at a place, the applicable lists appear as Here: - a supermarket shows the grocery list, a big-box store several at once.'
		],
		steps => [
			'Open Market from the start menu.',
			'Pick a list and a vendor to scope both tabs; both are kept on what you add.',
			'Type an item and press Enter to add it; set its dial to need or want.',
			'Switch to the Shopping tab and filter the run to needs, wants or all.',
			'At a shop, tap a Here: list to open on it.',
		'On a computer, press Scan and pick a phone (or This machine); each read comes back here, and Done puts the run on the list while Cancel (or the phone\'s Back) throws it away.',
			'Set an account\'s Payment type once in its Configure panel, so a receipt\'s tender finds that account.',
			'After a shop, press Receipt and scan the whole receipt in the ADF, then Add to cart and Checkout.',
			'In the confirm, check the date, paid-by and account against the page (fix them if the read is off), tick the lines, then Add to cart.',
			'After Checkout, the list\'s category opens with the expense transaction filled in - set each line\'s quantity and packaging, check the amounts, then press Save; that is when the purchase and its stock move are written.',
			'When a line needs a packaging the house does not know, press + beside Unit, name it, and say how many each it holds.',
			'Press Receipts to reopen a kept receipt: its pages open, and Add to list puts its lines back on the list.'
		],
		related => [ 'warehouse', 'store' ]
	};
$topic{'inventory'} = {
		title => 'Inventory', category => 'apps', app => 'inventory',
		verified => '2026-11-01',
		summary => 'An app\'s own record of what it holds and has been up to.',
		body => [
			'Inventory is the shared surface behind the apps: it holds the entries an app has recorded — a measure, a document, a report — and shows them together, with statistics. The Evaluation report and the controls that run it live at the foot of the app itself.',
			'The Share wheel is the scope on screen split into its own parts: a week into its seven days, a day into its hours, a month into its days, a year into its months, an hour into its minutes. Each slice names its part and its percentage of the scope, oldest first, and the percentages add up to 100; a scope with nothing recorded shows an empty wheel rather than a broken one. The wheel follows the Trend unit, so changing that select changes the share. The other two choices in the wheel\'s own list keep the older readings — where in the day and where in the week the time falls.',
			'The panel carries two colour sets, one for the light theme and one for the dark theme: the wheel\'s slices and the tint a cell wears for its budget status both read from them, so the two modes never borrow each other\'s colours.',
			'When Duration is shown, in Historical and Allocation alike, time is counted where it was actually spent: a session that runs from late evening into the next morning gives each day, hour and weekday the part that happened in it, while its occurrence stays with the period it started in. The same split is used by the app\'s duration budget, so an overnight session does not land wholly on the day it began.'
		],
		related => [ 'evaluation', 'measures', 'warehouse' ]
	};
1;
