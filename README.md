# CloudFormation Build Tool

#### Installation

* Install Python3
  
  `sudo apt install -y python3 python3-pip`
  
* Clone Repository

  ```
  cd ~/repositories
  git clone git@github.com:eonx-com/gitops-cloudformation.git
  ```
  
* Install CloudFormation Build Tool Dependencies
  
  ```
  cd ~/repositories/gitops-cloudformation
  pip3 install -r ./requirements.txt
  ```

#### Usage

`python3 CloudFormationBuilder.py --config=FILENAME.YML --path-tags=TAGS_PATH --path-templates=TEMPLATES_PATH`

#### Parameters

* --config

  Full path and filename to the configuration YAML file to be processed

* --path-templates

  Path where the compiled CloudFormation YML files will be saved
  
* --path-tags

  Path where JSON tag files will be saved. These are submitted along with stack deployment requests
  and saved on the resulting AWS CloudFormation stack.

#### Example Usage

The following example will consume the `build-manifest.json` file in the current directory and
output the JSON tag files into a subfolder called `./OutputTags` and the compiled CloudFormation
templates into the path `./OutputTemplates`

```bash
builder.py \
    --config=./build-manifest.json \
    --path-tags=./OutputTags \
    --path-templates=./OutputTemplates
```

