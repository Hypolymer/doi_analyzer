-- DOI Analyzer, version 1.5 (May 9, 2025)
-- This Server Addon was developed by Angela Persico (apersico@albany.edu; University at Albany), Bill Jones (jonesw@geneseo.edu; SUNY Geneseo), and Tim Jackson (Timothy.Jackson@suny.edu; SUNY Libraries Shared Services)
-- The purpose of this Addon is to clean up DOI fields and fetch a DOI from CrossRef if the DOI is missing
-- This Addon will attempt to extract an ISBN from a DOI if the DOI URL contains '978'
-- This Addon will also attempt to extract an ISBN from CrossRef metadata using a DOI lookup

local Settings = {};
Settings.QueueToMonitor = GetSetting("QueueToMonitor");
Settings.SuccessQueue = GetSetting("SuccessQueue");
Settings.FailureQueue = GetSetting("FailureQueue");
Settings.EmailAddress = GetSetting("EmailAddress");

local isCurrentlyProcessing = false;
local client = nil;

-- Assembly Loading and Type Importation
luanet.load_assembly("System");
local Types = {};
Types["WebClient"] = luanet.import_type("System.Net.WebClient");
Types["System.IO.StreamReader"] = luanet.import_type("System.IO.StreamReader");
Types["System.Type"] = luanet.import_type("System.Type");


function Init()
	LogDebug("DOI Analyzer > Initializing DOI ANALYZER Server Addon");
	RegisterSystemEventHandler("SystemTimerElapsed", "TimerElapsed");
end


function TimerElapsed(eventArgs)
	LogDebug("DOI Analyzer > Processing DOI ANALYZER Items");
	if not isCurrentlyProcessing then
		isCurrentlyProcessing = true;

		-- Process Items
		local success, err = pcall(ProcessItems);
		if not success then
			LogDebug("DOI Analyzer > There was a fatal error processing the items.")
			LogDebug("DOI Analyzer > Error: " .. err);
		end
		isCurrentlyProcessing = false;
	else
		LogDebug("DOI Analyzer > Still processing DOI ANALYZER Items");
	end
end

function ProcessItems()
	if Settings.QueueToMonitor == "" then
		LogDebug("DOI Analyzer > The configuration value for QueueToMonitor has not been set in the config.xml file.  Stopping Addon.");
	end
	if Settings.QueueToMonitor ~= "" then
		ProcessDataContexts("TransactionStatus", Settings.QueueToMonitor, "HandleContextProcessing");
	end
end

function rerun_checker()
	LogDebug("DOI Analyzer > Initializing function rerun_checker");
    local has_it_run = false;
	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	
	local connection = CreateManagedDatabaseConnection();
	connection.QueryString = "SELECT TransactionNumber FROM Notes WHERE TransactionNumber = '" .. transactionNumber .. "' AND NOTE = 'The DOI ANALYZER Addon ran on this transaction.'";
	connection:Connect();
	local rerun_status = connection:ExecuteScalar();
	connection:Disconnect();
	if rerun_status == transactionNumber then
		LogDebug('DOI Analyzer > rerun_checker > The DOI ANALYZER already ran on transaction ' .. transactionNumber .. '. Now Stopping Addon.');
		if Settings.ItemFailHoldRequestQueue ~= "" then
			ExecuteCommand("Route",{transactionNumber, Settings.FailureQueue});
			ExecuteCommand("AddNote",{transactionNumber, "ERROR: The DOI ANALYZER already ran on this transaction and it has been sitting in the " .. Settings.QueueToMonitor .. " processing queue. The TN is being routed to " .. Settings.FailureQueue .. ". Please remove the note that says 'The DOI ANALYZER Addon ran on this transaction.' and re-route the TN to the " .. Settings.QueueToMonitor .. " queue in order to reprocess the TN."});
		end	
		has_it_run = true;	
	end
	LogDebug("DOI Analyzer > rerun_checker > has_it_run equals: " .. tostring(has_it_run));
	return has_it_run;
end

function HandleContextProcessing()

	local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
	local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
	local the_doi = GetFieldValue("Transaction", "DOI");
	local ProcessType = GetFieldValue("Transaction", "ProcessType");
	local RequestType = GetFieldValue("Transaction", "RequestType");

	if ProcessType == "Borrowing" then
		if RequestType == "Article" then
			if rerun_checker() == false then
				ExecuteCommand("AddNote",{transactionNumber, "The DOI ANALYZER Addon ran on this transaction."});
				if the_doi ~= "" then
				FixDOI()		
				end
				if the_doi == "" then
				Get_CrossRef_DOI()	
				end
			end
		end
	end
end


local function contains_isbn_prefix(url)
LogDebug("DOI Analyzer > contains_isbn_prefix > url being processed: " .. url);
if string.find(url, "978") then
	LogDebug("DOI Analyzer > contains_isbn_prefix > found 978 in the URL");
	return true
else 
	LogDebug("DOI Analyzer > contains_isbn_prefix > did not find 978 in the URL");
	return false
end
end

function Get_CrossRef_DOI()
LogDebug("DOI Analyzer > Initializing function Get_CrossRef_DOI");
local url = "";
local currentTN_int = GetFieldValue("Transaction", "TransactionNumber");
local transactionNumber = luanet.import_type("System.Convert").ToDouble(currentTN_int);
local ISSN = GetFieldValue("Transaction", "ISSN");
-- Last Name of First Author
local PhotoArticleAuthor = GetFieldValue("Transaction", "PhotoArticleAuthor");
local PhotoArticleAuthor_edit = "";
if PhotoArticleAuthor ~= "" then
	PhotoArticleAuthor_edit = PhotoArticleAuthor:match("^(%S+)");
	PhotoArticleAuthor_edit = PhotoArticleAuthor_edit:gsub(',', '');
	LogDebug("DOI Analyzer > Get_CrossRef_DOI > Adjusted Author value: " .. PhotoArticleAuthor .. " to: " ..  PhotoArticleAuthor_edit .. " for CrossRef Lookup");
end

local PhotoJournalTitle = GetFieldValue("Transaction", "PhotoJournalTitle");
local PhotoJournalYear = GetFieldValue("Transaction", "PhotoJournalYear");
local PhotoJournalVolume = GetFieldValue("Transaction", "PhotoJournalVolume");
local PhotoJournalIssue = GetFieldValue("Transaction", "PhotoJournalIssue");

-- Only want value of first page
local PhotoJournalInclusivePages = GetFieldValue("Transaction", "PhotoJournalInclusivePages");
local PhotoJournalInclusivePages_edit = "";
if PhotoJournalInclusivePages ~= "" then
	PhotoJournalInclusivePages_edit = PhotoJournalInclusivePages:match("(%d+)");
	LogDebug("DOI Analyzer > Get_CrossRef_DOI > Adjusted Author value: " .. PhotoJournalInclusivePages .. " to: " ..  PhotoJournalInclusivePages_edit .. " for CrossRef Lookup");	
end

	-- Example usage
	--local reference = "https://doi.crossref.org/openurl?redirect=false&pid=jonesw@geneseo.edu&aulast=Kostos&title=Using%20Math%20Journals%20to%20Enhance%20Second%20Graders%20Communication%20of%20Mathematical%20Thinking&volume=38&issn=1082-3301&issue=3&date=2010";

	if Settings.EmailAddress ~= "" then
		
		url = "https://doi.crossref.org/openurl?redirect=false&pid=" .. Settings.EmailAddress;
		if PhotoArticleAuthor_edit ~= "" then
			url = url .. "&aulast=" .. PhotoArticleAuthor_edit;
		end
		if PhotoJournalTitle ~= "" then
			url = url .. "&title=" .. PhotoJournalTitle;
		end
		if PhotoJournalVolume ~= "" then
			url = url .. "&volume=" .. PhotoJournalVolume;
		end
		if ISSN ~= "" then
			url = url .. "&issn=" .. ISSN;
		end
		if PhotoJournalIssue ~= "" then
			url = url .. "&issue=" .. PhotoJournalIssue;
		end
		if PhotoJournalYear ~= "" then
			url = url .. "&date=" .. PhotoJournalYear;
		end
		if PhotoJournalInclusivePages_edit ~= "" then
			url = url .. "&spage=" .. PhotoJournalInclusivePages_edit
		end

		LogDebug("DOI Analyzer > Get_CrossRef_DOI > Full URL assembled for CrossRef API Lookup: " .. url);

	-- No Email Address found in Config
	else 
		LogDebug("DOI Analyzer > Get_CrossRef_DOI > You do not have a configuration value set for Settings.EmailAddress. Please set an email address to be sent with your CrossRef API calls.");
	end
	
	url = string.gsub(url, " ", "+");

    local webClient = Types["WebClient"]()
    webClient.Headers:Clear()
    webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8")
    webClient.Headers:Add("accept", "application/xml; charset=UTF-8")
	LogDebug("DOI Analyzer > Get_CrossRef_DOI > URL being sent to CrossRef: " .. url);
    local responseBytes = webClient:DownloadString(url)

	LogDebug("DOI Analyzer > Get_CrossRef_DOI > Response from CrossRef: " .. responseBytes);
    local doi;
    for tagContent in responseBytes:gmatch('">(.-)</doi>') do
        doi = tagContent:gsub('(.-)>', '');
		LogDebug("DOI Analyzer > Get_CrossRef_DOI > Extracted DOI from CrossRef: " .. doi);
        break
    end

	if doi then
		LogDebug("DOI Analyzer > Get_CrossRef_DOI > DOI: " .. tostring(doi));
		ExecuteCommand("AddNote",{transactionNumber, "DOI Analyzer > Extracted DOI from CrossRef: " .. tostring(doi)});
		SetFieldValue("Transaction", "DOI", doi);
        SaveDataSource("Transaction");

			if contains_isbn_prefix(doi) then

				local isbn_pattern = "/(978%d+)";
				local pulled_isbn = doi:match(isbn_pattern);

					if pulled_isbn then
							ExecuteCommand("AddNote",{transactionNumber, "DOI Analyzer > Extracted ISBN from DOI: " .. tostring(pulled_isbn)});
							LogDebug("DOI Analyzer > Get_CrossRef_DOI > Extracted ISBN from DOI: " .. tostring(pulled_isbn));
							SetFieldValue("Transaction", "ISSN", pulled_isbn);
							SaveDataSource("Transaction");
					else
						LogDebug("DOI Analyzer > No ISBN found in the URL.");
					end
			else
				LogDebug("DOI Analyzer > Get_CrossRef_DOI > contains_isbn_prefix > The URL does not contain '978'.");
				local isbn_lookup_url = "https://doi.crossref.org/openurl?redirect=false&pid=" .. Settings.EmailAddress .. "&format=unixref&doi=" .. doi;
				LogDebug("DOI Analyzer > Get_CrossRef_DOI > Attempting to extract ISBN from CrossRef metadata using URL: " .. isbn_lookup_url);
				local webClient = Types["WebClient"]();
				webClient.Headers:Clear();
				webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
				webClient.Headers:Add("Accept", "application/xml; charset=UTF-8");
				local responseString = webClient:DownloadString(isbn_lookup_url);
						
				if string.find(responseString, 'doi_records') ~= nil then
				--LogDebug(responseString);
				local found_isbn = responseString:match('<isbn media_type="print">(.-)</isbn>'):gsub('(.-)>', ''); -- look for found_isbn
					if found_isbn ~= "" then
						LogDebug("DOI Analyzer > Get_CrossRef_DOI > The item is showing an ISBN in the Crossref Metadata of [" .. found_isbn .. "]");
						ExecuteCommand("AddNote",{transactionNumber, "DOI Analyzer > Extracted ISBN from CrossRef Metadata using the DOI: [" .. found_isbn .. "]"});
						SetFieldValue("Transaction", "ISSN", found_isbn);
					    SaveDataSource("Transaction");
					end		
					if found_isbn == "" then
						LogDebug("DOI Analyzer > Get_CrossRef_DOI > No ISBN found in CrossRef Metadata using the DOI. Continue on.");
					end
				end	
			end
			
		ExecuteCommand("Route",{transactionNumber, Settings.SuccessQueue});
	else
		LogDebug("DOI Analyzer > Get_CrossRef_DOI > Unable to extract DOI from CrossRef.");
		LogDebug("DOI Analyzer > Get_CrossRef_DOI > Error: " .. tostring(err));
		ExecuteCommand("Route",{transactionNumber, Settings.FailureQueue});
		
	end
end

function FixDOI()
	local transactionNumber = GetFieldValue("Transaction", "TransactionNumber");
	local doi = GetFieldValue("Transaction", "DOI");
    local strippedDOI = doi:match("10%.%d+/.+");
    if strippedDOI then
        LogDebug("DOI Analyzer > FixDOI > Stripped DOI: " .. strippedDOI);
			SetFieldValue("Transaction", "DOI", strippedDOI);
            SaveDataSource("Transaction");
			
			if contains_isbn_prefix(doi) then

				local isbn_pattern = "/(978%d+)";
				local pulled_isbn = doi:match(isbn_pattern);

					if pulled_isbn then
							ExecuteCommand("AddNote",{transactionNumber, "DOI Analyzer > Extracted ISBN from DOI: " .. tostring(pulled_isbn)});
							LogDebug("DOI Analyzer > FixDOI > Extracted ISBN from DOI: " .. tostring(pulled_isbn));
							SetFieldValue("Transaction", "ISSN", pulled_isbn);
							SaveDataSource("Transaction");
					else
						LogDebug("DOI Analyzer > FixDOI > The URL does not contain '978'. No ISBN found in the URL.");
						local isbn_lookup_url = "https://doi.crossref.org/openurl?redirect=false&pid=" .. Settings.EmailAddress .. "&format=unixref&doi=" .. doi;
						LogDebug("DOI Analyzer > FixDOI > Attempting to extract ISBN from CrossRef metadata using URL: " .. isbn_lookup_url);
						local webClient = Types["WebClient"]();
						webClient.Headers:Clear();
						webClient.Headers:Add("Content-Type", "application/xml; charset=UTF-8");
						webClient.Headers:Add("Accept", "application/xml; charset=UTF-8");
						local responseString = webClient:DownloadString(isbn_lookup_url);
								
						if string.find(responseString, 'doi_records') ~= nil then
						--LogDebug(responseString);
						local found_isbn = responseString:match('<isbn media_type="print">(.-)</isbn>'):gsub('(.-)>', ''); -- look for found_isbn
							if found_isbn ~= "" then
								LogDebug("DOI Analyzer > FixDOI > The item is showing an ISBN in the Crossref Metadata of [" .. found_isbn .. "]");
								ExecuteCommand("AddNote",{transactionNumber, "DOI Analyzer > Extracted ISBN from CrossRef Metadata using a DOI: [" .. found_isbn .. "]"});
								LogDebug("DOI Analyzer > FixDOI > Extracted ISBN from CrossRef Metadata using a DOI: " .. tostring(pulled_isbn));
								SetFieldValue("Transaction", "ISSN", found_isbn);
								SaveDataSource("Transaction");
							end		
							if found_isbn == "" then
								LogDebug("DOI Analyzer > FixDOI > No ISBN found in CrossRef Metadata using the DOI. Continue on.");
							end
						end							
					end
			else
				LogDebug("DOI Analyzer > FixDOI > The URL does not contain '978'.");
			end						
			
			ExecuteCommand("Route",{transactionNumber, Settings.SuccessQueue});	
			if strippedDOI ~= doi then
				ExecuteCommand("AddNote",{transactionNumber, "Extracted DOI: " .. strippedDOI .. " from original DOI: " .. doi});	
				LogDebug("DOI Analyzer > FixDOI > Extracted DOI: " .. strippedDOI .. " from original DOI: " .. doi);
			end
        return strippedDOI;
    else
        LogDebugFormat("DOI Analyzer > FixDOI > Failed to strip DOI from: " .. doi);	
		ExecuteCommand("Route",{transactionNumber, Settings.FailureQueueQueue});			
        return nil;
    end
end
