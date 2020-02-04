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

`python3 CloudFormationBuilder.py [INPUT_FILENAME] [OUTPUT_FILENAME]`

#### Parameters

* INPUT_FILENAME

  Full path and filename to the configuration YAML file to be processed
  
* OUTPUT_FILENAME

  Full path and filename to which the CloudFormation YAML template should be rendered

#### Example Usage

```bash
cd ~/repositories/gitops-cloudformation

python3 CloudFormationBuilder.py ./Config/Dev/S3/EonxComBucket.yml ./Ouptut/Dev/S3/EonxComBucket.yml
```
