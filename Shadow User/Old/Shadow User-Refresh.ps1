Add-Type -AssemblyName System.Windows.Forms

# Function to get a list of OUs from the specified path
function Get-OUsFromPath {
    param (
        [string]$adPath
    )
    $ouList = @()
    try {
        $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://" + $adPath)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)
        $searcher.Filter = '(objectClass=organizationalUnit)'
        $searcher.SearchScope = [System.DirectoryServices.SearchScope]::OneLevel # Limit search depth to 1 (immediate child OUs)
        $result = $searcher.FindAll()

        foreach ($obj in $result) {
            $ouList += $obj.Properties['name'][0]
        }

        $result.Dispose()
        $searcher.Dispose()
        $entry.Dispose()
    } catch {
        Write-Host "Error: $_" -ForegroundColor Red
    }
    return $ouList
}

# Function to get a list of servers from the specified OU
function Get-ServersFromOU {
    param (
        [string]$adPath
    )
    $serverList = @()
    try {
        $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://" + $adPath)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)
        $searcher.Filter = '(objectClass=computer)'
        $result = $searcher.FindAll()

        foreach ($obj in $result) {
            $serverList += $obj.Properties['name'][0]
        }

        $result.Dispose()
        $searcher.Dispose()
        $entry.Dispose()
    } catch {
        Write-Host "Error: $_" -ForegroundColor Red
    }
    return $serverList
}

# Function to get a list of logged-in users from the specified server
function Get-LoggedUsersFromServer {
    param (
        [string]$serverName
    )
    $users = @()
    try {
        $sessions = query user /server:$serverName
        $sessions = $sessions | Where-Object { $_ -notmatch '^ USERNAME' }

        foreach ($session in $sessions) {
            $userProperties = $session -split '\s+'
            $objectProperties = [ordered]@{
                Username = $userProperties[1]
                SessionID = $userProperties[3]
                LogonTime = "$($userProperties[2]) $($userProperties[4])"
                Server = $serverName
            }
            $users += New-Object -TypeName PSObject -Property $objectProperties
        }
    } catch {
        Write-Host "Error: $_" -ForegroundColor Red
    }
    return $users
}

# Create a form
$form = New-Object Windows.Forms.Form
$form.Text = "Shadow User"
$form.Size = New-Object Drawing.Size(330, 260)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $false

# Function to show the users in a separate window and close the main form
function Show-Users {
    $selectedServers = $listBox.CheckedItems
    $usersList = @()

    foreach ($server in $selectedServers) {
        $users = Get-LoggedUsersFromServer $server
        foreach ($user in $users) {
            $userWithServer = New-Object PSObject -Property @{
                Username = $user.Username
                SessionID = $user.SessionID
                LogonTime = $user.LogonTime
                Server = $server
            }
            $usersList += $userWithServer
        }
    }

    $usersForm = New-Object Windows.Forms.Form
    $usersForm.Text = "Select a User"
    $usersForm.Size = New-Object Drawing.Size(510, 420)
    $usersForm.StartPosition = "CenterScreen"

    $usersGridView = New-Object Windows.Forms.DataGridView
    $usersGridView.Location = New-Object Drawing.Point(10, 30)
    $usersGridView.Size = New-Object Drawing.Size(470, 300)
    $usersGridView.AutoGenerateColumns = $false
    $usersGridView.MultiSelect = $false  # Allow only single selection

    # Add columns to the grid view
    $usernameCol = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $usernameCol.Name = "Username"
    $usernameCol.HeaderText = "Username"
    $usersGridView.Columns.Add($usernameCol)

    $sessionIdCol = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $sessionIdCol.Name = "SessionID"
    $sessionIdCol.HeaderText = "Session ID"
    $usersGridView.Columns.Add($sessionIdCol)

    $logonTimeCol = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $logonTimeCol.Name = "LogonTime"
    $logonTimeCol.HeaderText = "Logon Time"
    $usersGridView.Columns.Add($logonTimeCol)

    $serverCol = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $serverCol.Name = "Server"
    $serverCol.HeaderText = "RDS Server"
    $usersGridView.Columns.Add($serverCol)

    # Add each user session to the grid view (sorted alphabetically)
    $usersList | Sort-Object Username | ForEach-Object {
        $usersGridView.Rows.Add($_.Username, $_.SessionID, $_.LogonTime, $_.Server)
    }

    # Add a button to refresh the user list
    $refreshButton = New-Object Windows.Forms.Button
    $refreshButton.Location = New-Object Drawing.Point(10, 340)
    $refreshButton.Size = New-Object Drawing.Size(120, 30)
    $refreshButton.Text = "Refresh Users"
    $refreshButton.Add_Click({
        # Clear current users
        $usersGridView.Rows.Clear()
        # Reload users
        $selectedServers = $listBox.CheckedItems
        $usersList = @()

        foreach ($server in $selectedServers) {
            $users = Get-LoggedUsersFromServer $server
            foreach ($user in $users) {
                $userWithServer = New-Object PSObject -Property @{
                    Username = $user.Username
                    SessionID = $user.SessionID
                    LogonTime = $user.LogonTime
                    Server = $server
                }
                $usersList += $userWithServer
            }
        }

        # Add each user session to the grid view (sorted alphabetically)
        $usersList | Sort-Object Username | ForEach-Object {
            $usersGridView.Rows.Add($_.Username, $_.SessionID, $_.LogonTime, $_.Server)
        }
    })

    # Add a button to select the user
    $okButton = New-Object Windows.Forms.Button
    $okButton.Location = New-Object Drawing.Point(360, 340)
    $okButton.Size = New-Object Drawing.Size(120, 30)
    $okButton.Text = "Connect"
    $okButton.DialogResult = [Windows.Forms.DialogResult]::OK
    $usersForm.AcceptButton = $okButton

    # Add controls to the users form
    $usersForm.Controls.Add($usersGridView)
    $usersForm.Controls.Add($okButton)
    $usersForm.Controls.Add($refreshButton)

    # Show the users form and close the main form on selection
    $form.Hide()  # Hide the main form
    $result = $usersForm.ShowDialog()
    $form.Close() # Close the main form when users form is closed

    if ($result -eq [Windows.Forms.DialogResult]::OK) {
        $selectedRowIndex = $usersGridView.SelectedCells[0].RowIndex
        if ($selectedRowIndex -ge 0) {
            $selectedSessionID = $usersGridView.Rows[$selectedRowIndex].Cells["SessionID"].Value
            $selectedServer = $usersGridView.Rows[$selectedRowIndex].Cells["Server"].Value
            Write-Host "Selected User: $($usersGridView.Rows[$selectedRowIndex].Cells["Username"].Value), Session ID: $selectedSessionID, RDS Server: $selectedServer"
            $response = [Windows.Forms.MessageBox]::Show("Do you want to shadow $($usersGridView.Rows[$selectedRowIndex].Cells["Username"].Value)?", "Shadow User", [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
            if ($response -eq [Windows.Forms.DialogResult]::Yes) {
                mstsc /v:$selectedServer /shadow:$selectedSessionID /control
            }
        } else {
            Write-Host "No user selected."
        }
    }
}

# Create a label for the text field
$label = New-Object Windows.Forms.Label
$label.Location = New-Object Drawing.Point(10, 20)
$label.Size = New-Object Drawing.Size(300, 20)
$label.Text = "Choose a client:"
$form.Controls.Add($label)

# Create a drop-down list
$dropDown = New-Object Windows.Forms.ComboBox
$dropDown.Location = New-Object Drawing.Point(10, 40)
$dropDown.Size = New-Object Drawing.Size(300, 25)
$dropDown.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

# Add OU options to the drop-down and sort alphabetically
$adPath = "OU=RDS Servers,OU=Servers,DC=focusnet,DC=net,DC=au"
$ouOptions = Get-OUsFromPath $adPath
$ouOptions | Sort-Object | ForEach-Object { $dropDown.Items.Add($_) }

# Create a ListBox to display the list of servers with checkboxes
$listBox = New-Object Windows.Forms.CheckedListBox
$listBox.Location = New-Object Drawing.Point(10, 70)
$listBox.Size = New-Object Drawing.Size(300, 100)

# Event handler to populate the ListBox with servers when an OU is selected
$dropDown.add_SelectedIndexChanged({
    $selectedOU = $dropDown.SelectedItem.ToString()
    $ouPath = "OU=$selectedOU,$adPath"
    $servers = Get-ServersFromOU $ouPath
    $listBox.Items.Clear()
    $servers | ForEach-Object { $listBox.Items.Add($_, $true) }
})

# Create a button to show users
$showUsersButton = New-Object Windows.Forms.Button
$showUsersButton.Location = New-Object Drawing.Point(160, 180)
$showUsersButton.Size = New-Object Drawing.Size(150, 30)
$showUsersButton.Text = "Show Users"
$showUsersButton.Add_Click({ Show-Users })

# Add controls to the form
$form.Controls.Add($dropDown)
$form.Controls.Add($listBox)
$form.Controls.Add($showUsersButton)

# Show the form
$form.ShowDialog() | Out-Null
