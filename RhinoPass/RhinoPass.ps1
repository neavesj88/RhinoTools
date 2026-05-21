# Add necessary assembly to use Windows Forms
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Create the form
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Rhino Pass'
$form.Size = New-Object System.Drawing.Size(450, 250)

# Load Rhino Image
$rhinoImage = [System.Drawing.Image]::FromFile('C:\Scripts\RhinoPass\Rhino.png')
$rhinoPictureBox = New-Object System.Windows.Forms.PictureBox
$rhinoPictureBox.Image = $rhinoImage
$rhinoPictureBox.Size = New-Object System.Drawing.Size(100, 110)
$rhinoPictureBox.Location = New-Object System.Drawing.Point(10, 15)
$rhinoPictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
$form.Controls.Add($rhinoPictureBox)

# Create a label for instruction
$instructionLabel = New-Object System.Windows.Forms.Label
$instructionLabel.Size = New-Object System.Drawing.Size(300, 30)
$instructionLabel.Location = New-Object System.Drawing.Point(120, 20)
$instructionLabel.Text = 'Click the button to generate a password:'
$form.Controls.Add($instructionLabel)

# Create a TextBox for displaying the generated password (Selectable)
$passwordTextBox = New-Object System.Windows.Forms.TextBox
$passwordTextBox.Size = New-Object System.Drawing.Size(300, 30)
$passwordTextBox.Location = New-Object System.Drawing.Point(120, 50)
#$passwordTextBox.ReadOnly = $true
$passwordTextBox.BackColor = [System.Drawing.Color]::White
$passwordTextBox.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$passwordTextBox.TextAlign = 'Center'
$passwordTextBox.Text = ''
$passwordTextBox.Font = New-Object System.Drawing.Font("Arial", 14)
$form.Controls.Add($passwordTextBox)

# Create a label for rhino phrases
$rhinoLabel = New-Object System.Windows.Forms.Label
$rhinoLabel.Size = New-Object System.Drawing.Size(360, 30)
$rhinoLabel.Location = New-Object System.Drawing.Point(120, 90)
$rhinoLabel.Text = 'Hello! Ready to make a password?'
$form.Controls.Add($rhinoLabel)

# Checkboxes for Capital Letters and Special Characters
$capitalCheckbox = New-Object System.Windows.Forms.CheckBox
$capitalCheckbox.Location = New-Object System.Drawing.Point(120, 125)
$capitalCheckbox.Text = "Capital Letters"
$form.Controls.Add($capitalCheckbox)

$specialCheckbox = New-Object System.Windows.Forms.CheckBox
$specialCheckbox.Location = New-Object System.Drawing.Point(270, 125)
$specialCheckbox.Size = New-Object System.Drawing.Size(150, 30)
$specialCheckbox.Text = "Special Characters"
$form.Controls.Add($specialCheckbox)

# Create a button to generate a password
$generateButton = New-Object System.Windows.Forms.Button
$generateButton.Size = New-Object System.Drawing.Size(150, 30)
$generateButton.Location = New-Object System.Drawing.Point(270, 155)
$generateButton.Text = 'Generate Password'
$form.Controls.Add($generateButton)

# Create a button to copy the password to clipboard
$copyButton = New-Object System.Windows.Forms.Button
$copyButton.Size = New-Object System.Drawing.Size(100, 30)
$copyButton.Location = New-Object System.Drawing.Point(120, 155)
$copyButton.Text = 'Copy Text'
$form.Controls.Add($copyButton)

# Mood Phrases
$cheerfulPhrases = @("Here's a good one!", "Another one? Okay!", "Passwords are great!", "I love passwords!", "I wonder what the ticket queue is like!", "Here is a super password for you!", "Passwords!", "Passwords for everyone!", "You get a password, and you get a password!", "P-P-Passwords!")
$annoyedPhrases = @("Really? Again?", "I think this one is the one!", "This one is pretty decent...", "Perfect password right here", "This one is fine", "Here...", "You don't stop, huh?", "I could be doing something else, you know.", "Ugh, here we go again...", "This is the last one, I swear!")
$angryPhrases = @("No more passwords for you!", "I’m not a Pipsqueak!", "ANDREW!")
$recoveredPhrases = @("Nah, I love doing my job, unlike CMTG, another password!")

# Initialize Mood Variables
$global:phraseIndex = 0
$global:cheerfulCount = 0
$global:annoyedCount = 0
$global:angryCount = 0
$global:currentPhase = 'cheerful'

# List of adjectives and nouns
$adjectiveList = @(
    "happy", "small", "big", "green", "bright", "funny", "fast", "slow", "friendly", "blue", "soft", "loud", "quiet", "strong", "weak", "cute", "kind", "red", "yellow", 
    "fluffy", "beautiful", "cool", "slim", "wide", "round", "sharp", "tall", "short", "old", "new", "young", "dark", "light", "shiny", "bouncy", "wild", "pretty", "lovely", 
    "sweet", "clean", "clear", "messy", "hard", "easy", "warm", "tough", "soft", "slow", "calm", "brave", "smart", "sleepy", "black", "silly", "fuzzy", "gentle", "narrow", "smooth", "rough", "heavy", "rich", "cold", "thin", "thick", "tasty", "spicy", "sparkly", "energetic", "glossy", "grumpy", 
    "shy", "lively", "chilly", "rainy", "moody", "polished", "delicate", "sophisticated", "unique", "unusual", "serene", "magical", "witty", "charming", 
    "flawless", "elegant", "brilliant", "muscular", "chunky", "modern", "classic", "rustic", "wholesome", "eager", "icy", "bold", "spunky"
) | Select-Object -Unique
$nounList = @("apple", "banana", "cat", "dog", "elephant", "fish", "giraffe", "hat", "ice", "jump", "kite", "lemon", "moon", "nest", "orange", "pencil", "queen", "rocket", "sun", "tiger", 
    "umbrella", "violet", "whale", "zebra", "ant", "bird", "car", "doll", "egg", "flower", "goat", "house", "igloo", "jelly", "key", "lamp", "mango", "noodle", "owl", 
    "pumpkin", "rain", "star", "tree", "unicorn", "vulture", "water", "zoo", "acorn", "ball", "cloud", "dragon", "fan", "grape", "island", "jaguar", "koala", "lemonade", 
    "monkey", "nurse", "ocean", "parrot", "quilt", "robot", "snow", "turtle", "volcano", "whale", "xmas", "arrow", "balloon", "candy", "dinosaur", "fox", "glove", "honey", 
    "icecream", "jewel", "lollipop", "mountain", "panda", "rose", "strawberry", "watermelon", "book", "frog", "hug", "ink", "jug", "kettle", "love", "mouse", "night", 
    "oak", "peach", "ribbon", "train", "wagon", "actor", "cup", "light", "necklace", "puzzle", "snowflake", "tail", "vacuum", "worm", "apron", "circle", "doghouse", "ear", 
    "fountain", "guitar", "jigsaw", "lighthouse", "moose", "nose", "open", "plane", "rocket", "space", "tulip", "walnut", "angel", "cake", "duck", "flame", "goose", 
    "jar", "key", "log", "net", "octopus", "potato", "rainbow", "watch", "yoga", "airplane", "bicycle", "couch", "ferris", "glue", "hand", "jellybean", "lunch", "moth", 
    "neck", "pencil", "sunshine", "zigzag", "balloon", "cloud", "iceberg", "jungle", "kingdom", "leap", "mermaid", "notebook", "oasis", "palm", "quack", "race", 
    "seahorse", "trail", "umbrella", "vulture", "whisker", "xenon", "yellow", "alien", "bread", "clown", "dove", "echo", "fence", "gate", "hike", "ivy", "joke", "kiwi", 
    "lion", "mango", "nut", "orange", "pearl", "rain", "sunset", "turtle", "wind", "xylophone", "yarn", "armadillo", "bear", "camel", "deer", "flamingo", 
    "hippopotamus", "iguana", "jaguar", "kangaroo", "leopard", "moose", "narwhal", "ocelot", "penguin", "quail", "raccoon", "squirrel", "toucan", "walrus", "yak", 
    "zebu", "alpaca", "bison", "chicken", "dolphin", "eagle", "feline", "hawk", "impala", "jellyfish", "koala", "lynx", "meerkat", "otter", "pigeon", "quokka", "rabbit", 
    "snake", "tortoise", "person", "air", "ball", "carrot", "drum", "ear", "flag", "guitar", "hamster", "iceberg", "jewel", "map", "puzzle", "rose", "telescope", "vase", "whistle", "yacht", 
    "bee", "cactus", "dove", "frog", "grapes", "horse", "iron", "needle", "pyramid", "rabbit", "tree", "waterfall", "zombie", "eggplant", "garden", "helicopter", "island", 
    "monster", "nachos", "pillow", "starfish", "train", "yogurt", "zeppelin"
) | Select-Object -Unique

# Function to generate a password
$generatePassword = {
    $adjective = Get-Random -InputObject $adjectiveList
    $noun = Get-Random -InputObject $nounList
    $adjective = $adjective.Substring(0, 1).ToUpper() + $adjective.Substring(1)
    $digits = Get-Random -Minimum 10 -Maximum 99

    if ($capitalCheckbox.Checked) {
        $adjective = $adjective.Substring(0,1).ToUpper() + $adjective.Substring(1)
        $noun = $noun.Substring(0,1).ToUpper() + $noun.Substring(1)
    }

    $password = "$adjective$noun$digits"

    if ($specialCheckbox.Checked) {
        $password = $password -replace "a", "@" -replace "s", "$" -replace "o", "0" -replace "i", "!"
    }

    return $password
}

# Button Click Event
$generateButton.Add_Click({
    switch ($global:currentPhase) {
        'cheerful' {
            $password = $generatePassword.Invoke()
            $passwordTextBox.Text = $password
            $rhinoLabel.Text = $cheerfulPhrases[$global:phraseIndex % $cheerfulPhrases.Count]
            $global:phraseIndex++
            $global:cheerfulCount++

            if ($global:cheerfulCount -ge 10) {
                $global:currentPhase = 'annoyed'
                $global:cheerfulCount = 0
            }
            break
        }
        'annoyed' {
            $password = $generatePassword.Invoke()
            $passwordTextBox.Text = $password
            $rhinoLabel.Text = $annoyedPhrases[$global:phraseIndex % $annoyedPhrases.Count]
            $global:phraseIndex++
            $global:annoyedCount++

            if ($global:annoyedCount -ge 10) {
                $global:currentPhase = 'angry'
                $global:annoyedCount = 0
            }
            break
        }
        'angry' {
            $passwordTextBox.Text = ''
            $rhinoLabel.Text = $angryPhrases[$global:angryCount % $angryPhrases.Count]
            $global:angryCount++

            if ($global:angryCount -ge 3) {
                $global:currentPhase = 'recovered'
                $global:angryCount = 0
            }
            break
        }
        'recovered' {
            $password = $generatePassword.Invoke()
            $passwordTextBox.Text = $password
            $rhinoLabel.Text = $recoveredPhrases[0]
            $global:currentPhase = 'cheerful'
            break
        }
    }
})

# Copy Button Event
$copyButton.Add_Click({
    [System.Windows.Forms.Clipboard]::SetText($passwordTextBox.Text)
})

# Show the Form
$form.ShowDialog()
