#!/usr/bin/env python3

import argparse
import base64
import json
import os
import re
import secrets
import time
import yaml

from datetime import datetime
from pprint import pprint


# noinspection DuplicatedCode
class CloudFormationBuilder:
    __templates__ = {}
    __environment__ = ''
    __input_filename__ = ''
    __project__ = ''
    __debug_output__ = False
    __references_convert_to_camel_case__ = True
    __references_prefix_environment__ = False
    __references_prefix_project__ = False

    @staticmethod
    def debug_print(message=''):
        if CloudFormationBuilder.__debug_output__ is True:
            print(message)

    @staticmethod
    def generate(environment, project, input_filename, output_filename, tags_filename, aws_account_id, aws_default_region, service_definition) -> None:
        """
        Generate output template

        :type environment: str
        :param environment: Deployment environment
        
        :type project: str
        :param project: Deployment environment

        :type input_filename: str
        :param input_filename: The input filename

        :type output_filename: str
        :param output_filename: The output filename

        :type tags_filename: str
        :param tags_filename: The tags filename

        :type aws_account_id: str
        :param aws_account_id: Account where stack will be deployed

        :type aws_default_region: str
        :param aws_default_region: Region where stack will be deployed

        :type service_definition: str
        :param service_definition: Harness service definition type (application/infrastructure)
        """
        # Make sure the input filename can be found
        if os.path.exists(input_filename) is False:
            raise Exception('The specified input filename ({input_filename}) does not exists'.format(input_filename=input_filename))

        CloudFormationBuilder.__input_filename__ = input_filename
        CloudFormationBuilder.__project__ = project
        CloudFormationBuilder.environment = environment

        # Read the input file and process into a dictionary
        file = open(input_filename, 'rt')
        yaml_content = yaml.full_load(file)
        file.close()

        # Make sure YAML template contains required root keys
        required_keys = ['template', 'records']
        for key in required_keys:
            if key not in yaml_content.keys():
                raise Exception('Configuration file missing required "{key}" key'.format(key=key))

        # Make sure YAML template key contains required template configuration keys
        required_keys = ['description', 'author_name', 'author_email']
        for key in required_keys:
            if key not in yaml_content['template'].keys():
                raise Exception('Configuration file missing required "template.{key}" value'.format(key=key))

        template = yaml_content['template']

        # Make sure the output filename path exists
        output_path = os.path.dirname(output_filename)

        if len(output_path) > 0:
            os.makedirs(output_path, exist_ok=True)
        else:
            os.makedirs('./Output', exist_ok=True)

        # Keep track of the records to be created
        records = {
            'resource': {},
            'parameter': {},
            'output': {}
        }

        # Start creating output YAML file
        rendered = 'AWSTemplateFormatVersion: "2010-09-09"\n'
        rendered += 'Description: {description}\n'.format(description=template['description'])

        rendered += '\n'
        rendered += '# ----------------------------------------------------------------------------------------\n'
        rendered += '# STACK METADATA\n'
        rendered += '# ----------------------------------------------------------------------------------------\n'
        rendered += '\n'
        rendered += 'Metadata:\n'
        rendered += '\n'
        rendered += '  Project: {project}\n'.format(project=CloudFormationBuilder.to_camel(project))
        rendered += '  Environment: {environment}\n'.format(environment=CloudFormationBuilder.to_camel(environment))
        rendered += '  Service: {service_definition}\n'.format(service_definition=CloudFormationBuilder.to_camel(service_definition))
        rendered += '  Account: {account}\n'.format(account=aws_account_id)
        rendered += '  Region: {region}\n'.format(region=aws_default_region)
        rendered += '  AuthorName: {author_name}\n'.format(author_name=template['author_name'])
        rendered += '  AuthorEmail: {author_email}\n'.format(author_email=template['author_email'])

        # Iterate all records and record the details of items we need to create
        for record_id, record in yaml_content['records'].items():
            # Validate the record
            CloudFormationBuilder.validate_record(record)

            # Store the current record for rendering
            records[record['type']][record_id] = record

            # If the record outputs were requested, add that as well (along with the record they relate to)
            if 'outputs' in record.keys():
                for output in record['outputs']:
                    output['_record_id'] = record_id

                    if '_name' in output:
                        output_id = output['_name']
                    else:
                        output_id = output['_id']

                    records['output'][output_id] = {
                        'record': record,
                        'record_id': record_id,
                        'output': output
                    }

        # Render stack parameters
        if len(records['parameter']) > 0:
            CloudFormationBuilder.debug_print('Creating Stack Parameters')
            CloudFormationBuilder.debug_print()
            rendered += '\n'
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '# STACK PARAMETERS\n'
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '\n'
            rendered += 'Parameters:\n'
            for parameter_id, parameter in records['parameter'].items():
                rendered += CloudFormationBuilder.render_value(template, parameter_id, parameter)
            CloudFormationBuilder.debug_print()

        # Render stack resources
        if len(records['resource']) > 0:
            CloudFormationBuilder.debug_print('Creating Stack Resources')
            CloudFormationBuilder.debug_print()
            rendered += '\n'
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '# STACK RESOURCES\n'
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '\n'
            rendered += 'Resources:\n'

            for resource_id, resource in records['resource'].items():
                if 'tags' in resource:
                    if resource['tags'] is True:
                        if 'properties' not in resource['config']:
                            resource['config']['properties'] = {}
                        if 'tags' not in resource['config']['properties']:
                            resource['config']['properties']['tags'] = []

                        resource['config']['properties']['tags'].append({
                            'Key': 'Name',
                            'Value': CloudFormationBuilder.to_aws_ref(
                                name=resource_id,
                                project=project,
                                environment=environment
                            )
                        })

                        for key, value in template.items():
                            resource['config']['properties']['tags'].append({
                                'Key': CloudFormationBuilder.to_aws_ref(key),
                                'Value': value
                            })

                rendered += CloudFormationBuilder.render_value(template, resource_id, resource)

            CloudFormationBuilder.debug_print()

        # Render stack outputs
        if len(records['output']) > 0:
            CloudFormationBuilder.debug_print('Creating Stack Outputs')
            CloudFormationBuilder.debug_print()
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '# STACK OUTPUTS\n'
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '\n'
            rendered += 'Outputs:\n'
            rendered += '\n'
            for key, value in records['output'].items():
                output = value['output']

                if '_name' in output:
                    output_id = CloudFormationBuilder.to_aws_ref(
                        name=output['_name'],
                        environment=environment,
                        project=project
                    )
                else:
                    output_id = CloudFormationBuilder.to_aws_ref(
                        name=key,
                        environment=environment,
                        project=project
                    )

                CloudFormationBuilder.debug_print('\t- {output_id}'.format(output_id=output_id))

                output_value = CloudFormationBuilder.render_dict(template, output, indent=2)

                rendered += '  {output_id}:\n'.format(output_id=output_id)
                rendered += '    Value: {output_value}\n'.format(output_value=output_value)

                if '_description' in output:
                    rendered += '    Description: {description}\n'.format(description=output['_description'])

                rendered += '    Export:\n'
                rendered += '      Name: {output_id}\n'.format(output_id=output_id)

            CloudFormationBuilder.debug_print()

        # Remove all blank lines from template output
        rendered_split = rendered.split('\n')
        rendered = ''
        for line in rendered_split:
            if len(line.strip()) > 0:
                rendered += line + '\n'

        print('  * Writing Template: {output_filename} ({bytes} Bytes)'.format(output_filename=os.path.basename(output_filename), bytes=len(rendered)))

        # Write output file to disk
        file = open(output_filename, 'wt')
        file.write(rendered)
        file.close()

        # Write tag string to file for CLI stack operations
        if tags_filename is not None:
            CloudFormationBuilder.debug_print('Saving Tag File: {tags_filename}'.format(tags_filename=tags_filename))

            tags = [
                {'Key': 'Project', 'Value': project.lower()},
                {'Key': 'Service', 'Value': service_definition.lower()},
                {'Key': 'Environment', 'Value': environment.lower()},
                {'Key': 'Account', 'Value': str(aws_account_id)},
                {'Key': 'Region', 'Value': aws_default_region.lower()},
                {'Key': 'AuthorName', 'Value': template['author_name']},
                {'Key': 'AuthorEmail', 'Value': template['author_email']}
            ]

            file = open(tags_filename, 'wt')
            file.write(json.dumps(tags))
            file.close()

    @staticmethod
    def render_value(template, name, value) -> str:
        parameter_aws_ref = CloudFormationBuilder.to_aws_ref(
            name=name,
            project=CloudFormationBuilder.__project__,
            environment=CloudFormationBuilder.environment
        )
        CloudFormationBuilder.debug_print('\t - {parameter_aws_ref}'.format(parameter_aws_ref=parameter_aws_ref))

        rendered = '\n'

        if 'title' in value:
            rendered += '  # ----------------------------------------------------------------------------------------\n'
            rendered += '  # {title}\n'.format(title=value['title'])
            rendered += '  # ----------------------------------------------------------------------------------------\n'
            rendered += '\n'

        if 'comment' in value:
            rendered += '  # {comment}\n'.format(comment=value['comment'])

        rendered += '  {parameter_aws_ref}:\n'.format(parameter_aws_ref=parameter_aws_ref)

        for config_key, config_value in value['config'].items():
            name = CloudFormationBuilder.to_aws_ref(name=config_key)

            if isinstance(config_value, list):
                value = CloudFormationBuilder.render_list(template, config_value, indent=2)

            elif isinstance(config_value, dict):
                value = CloudFormationBuilder.render_dict(template, config_value, indent=2)
            else:
                value = ' {config_value}'.format(config_value=config_value)

            rendered += '    {key}:{value}\n'.format(key=name, value=value)

        return rendered

    @staticmethod
    def render_list(template, value, indent=0, newline=True):
        output = ''
        for item in value:
            if newline is True:
                output += '\n'
                for i in range(0, indent):
                    output += '  '

            newline = True

            output += '  -'

            if isinstance(item, list):
                output += CloudFormationBuilder.render_list(template, item, indent + 1, newline=False)
            elif isinstance(item, dict):
                output += CloudFormationBuilder.render_dict(template, item, indent + 1, newline=False)
            else:
                output += ' {item}\n'.format(item=item)

        return output

    @staticmethod
    def render_dict(template, value, indent=0, newline=True):
        rendered = ' '

        if '_type' in value.keys():
            # AWS reference
            value_type = value['_type']
            if value_type.lower() == 'self':
                # Reference to self
                rendered += '!Ref {output_ref}'.format(
                    output_ref=CloudFormationBuilder.to_aws_ref(
                        name=value['_record_id'],
                        environment=CloudFormationBuilder.environment,
                        project=CloudFormationBuilder.__project__
                    )
                )
            if value_type.lower() == 'string':
                rendered += str(value['_value'])
            if value_type.lower() == 'token_hex':
                if '_length' in value:
                    rendered += str(secrets.token_hex(value['_length']))
                else:
                    rendered += str(secrets.token_hex(16))
            if value_type.lower() == 'include':
                directory = os.path.dirname(CloudFormationBuilder.__input_filename__)
                include_filename = value['_filename']
                include_file = open('{directory}/{include_filename}'.format(include_filename=include_filename, directory=directory), 'rt')
                item = yaml.full_load(include_file)

                rendered += '\n'
                for i in range(0, indent):
                    rendered += '  '

                if isinstance(item, list):
                    rendered += CloudFormationBuilder.render_list(template, item, indent, newline=False)
                elif isinstance(item, dict):
                    rendered += CloudFormationBuilder.render_dict(template, item, indent, newline=False)
                else:
                    rendered += '{item}'.format(item=item)

            if value_type.lower() == 'ref':
                # Reference to another resource in same stack
                rendered += '!Ref {id}'.format(
                    id=CloudFormationBuilder.to_aws_ref(
                        name=value['_id'],
                        project=CloudFormationBuilder.__project__,
                        environment=CloudFormationBuilder.environment
                    )
                )
            elif value_type.lower() == 'depends-on':
                # Depends on reference
                rendered += '{id}'.format(
                    id=CloudFormationBuilder.to_aws_ref(
                        name=value['_id'],
                        project=CloudFormationBuilder.__project__,
                        environment=CloudFormationBuilder.environment
                    )
                )
            elif value_type.lower() == 'importvalue_origin_access_identity_id':
                # Depends on reference
                indent = ''

                if '_indent' in value:
                    for i in range(0, value['_indent']):
                        indent += '  '

                rendered += '!Join\n{indent}- "/"\n{indent}- - "origin-access-identity/cloudfront"\n{indent}  - !ImportValue {id}'.format(
                    indent=indent,
                    id=CloudFormationBuilder.to_aws_ref(
                        name=value['_id'],
                        project=CloudFormationBuilder.__project__,
                        environment=CloudFormationBuilder.environment
                    )
                )
            elif value_type.lower() == 'importvalue_origin_access_identity_iam_user':
                # Depends on reference
                indent = ''

                if '_indent' in value:
                    for i in range(0, value['_indent']):
                        indent += '  '

                rendered += '!Join\n{indent}- "/"\n{indent}- - "arn:aws:iam::cloudfront:user"\n{indent}  - !ImportValue {id}'.format(
                    indent=indent,
                    id=CloudFormationBuilder.to_aws_ref(
                        name=value['_id'],
                        project=CloudFormationBuilder.__project__,
                        environment=CloudFormationBuilder.environment
                    )
                )
            elif value_type.lower() == 'camel-prefixed':
                # ProjectEnvironmentXXX prefixed name
                rendered += CloudFormationBuilder.to_aws_ref(
                    name=value['_value'],
                    project=CloudFormationBuilder.__project__,
                    environment=CloudFormationBuilder.environment
                )
            elif value_type.lower() == 'snake-prefixed':
                # project-environment-xxx prefixed name
                rendered += CloudFormationBuilder.to_snake(CloudFormationBuilder.to_aws_ref(
                    name=value['_value'],
                    project=CloudFormationBuilder.__project__,
                    environment=CloudFormationBuilder.environment
                ))
            elif value_type.lower() == 'base64':
                # Base64 function call
                rendered += '!Base64 {value}'.format(
                    value=value['_value']
                )
            elif value_type.lower() == 'base64_encode':
                # Base64 value substitution
                rendered += '{value}'.format(
                    value=base64.encodebytes(bytes(value['_value'], 'utf-8')).decode('ascii').replace('\n', '').strip()
                )
            elif value_type.lower() == 'getatt':
                rendered += '!GetAtt {id}.{attribute}'.format(
                    id=CloudFormationBuilder.to_aws_ref(
                        name=value['_id'],
                        project=CloudFormationBuilder.__project__,
                        environment=CloudFormationBuilder.environment
                    ),
                    attribute=value['_attribute']
                )
            elif value_type.lower() == 'join':
                # Depends on reference
                indent = ''

                if '_indent' in value:
                    for i in range(0, value['_indent']):
                        indent += '  '
                else:
                    value['_indent'] = 0

                if '_join_string' not in value.keys():
                    value['_join_string'] = ''

                rendered += '!Join\n{indent}  - "{join_string}"\n{indent}  - '.format(
                    indent=indent,
                    join_string=value['_join_string']
                )

                count = 0
                for item in value['_items']:
                    rendered_value = ''
                    if isinstance(item, list):
                        rendered_value = CloudFormationBuilder.render_list(template, item, value['_indent'] + 1, newline=False)
                    elif isinstance(item, dict):
                        rendered_value = CloudFormationBuilder.render_dict(template, item, value['_indent'] + 1, newline=False)
                    else:
                        rendered_value = ' {item}'.format(item=item)

                    if count > 0:
                        rendered += '{indent}    '.format(indent=indent)

                    rendered += '-{rendered_value}\n'.format(
                        indent=indent,
                        rendered_value=rendered_value
                    )
                    count = count + 1
            elif value_type.lower() == 'environment':
                if '_case' in value.keys():
                    if value['_case'].lower() == 'lower':
                        rendered += str(environment_id).lower()
                    elif value['_case'].lower() == 'upper':
                        rendered += str(environment_id).upper()
                    else:
                        rendered += str(environment_id)
                else:
                    rendered += str(environment_id)
            elif value_type.lower() == 'project':
                if '_case' in value.keys():
                    if value['_case'].lower() == 'lower':
                        rendered += str(project_id).lower()
                    elif value['_case'].lower() == 'upper':
                        rendered += str(project_id).upper()
                    else:
                        rendered += str(project_id)
                else:
                    rendered += str(environment_id)
            elif value_type.lower() == 'importvalue':
                rendered += '!ImportValue {id}'.format(
                    id=CloudFormationBuilder.to_aws_ref(
                        name=value['_id'],
                        project=CloudFormationBuilder.__project__,
                        environment=CloudFormationBuilder.environment
                    )
                )
        else:
            for record_id, record in value.items():
                # Boring old dictionary

                if newline is True:
                    rendered += '\n'
                    for i in range(0, indent + 1):
                        rendered += '  '

                if str(record_id).startswith('~'):
                    rendered += '{id}:'.format(id=record_id[1:])
                else:
                    rendered += '{id}:'.format(id=CloudFormationBuilder.to_aws_ref(record_id))

                if isinstance(record, list):
                    rendered += CloudFormationBuilder.render_list(template, record, indent + 1)
                elif isinstance(record, dict):
                    rendered += CloudFormationBuilder.render_dict(template, record, indent + 1)
                else:
                    rendered += ' {item}'.format(item=record)

                newline = True

        return rendered

    @staticmethod
    def validate_record(record):
        """
        Validate YAML record contains required keys based on its type
        """
        try:
            # Make sure a type and config was specified for each record
            if 'type' not in record.keys():
                raise Exception('Invalid YAML configuration, missing required "type" key')

            if 'config' not in record.keys():
                raise Exception('Invalid YAML configuration, missing required "config" key')

            record_type = record['type']

            # Make sure record type is known
            if record_type not in ['parameter', 'resource']:
                raise Exception('Unknown record type specified')

            if record_type == 'tags':
                if isinstance(record, dict) is False:
                    raise Exception('Invalid data type for "tags" key, expected dictionary')

                for key, value in record.items():
                    if isinstance(value, dict) is True or isinstance(value, list) is True:
                        raise Exception('Invalid data type for "tags" key, values must be a scalar type')
            else:
                # Make sure all other record specify a "type" and "config"
                required_keys = ['type', 'config']
                for key in required_keys:
                    if key not in record.keys():
                        raise Exception('Configuration file missing required "{key}" value in record'.format(key=key))

                # Make sure the type is a string value
                if isinstance(record['type'], str) is False:
                    raise Exception('Configuration file specified an invalid "type" value, expecting string value')

                # Make sure the config is a dictionary value
                if isinstance(record['config'], dict) is False:
                    raise Exception('Configuration file specified an invalid "config" value, expecting dictionary value')

                # If an output key exists on the record it must be a dictionary value
                if 'outputs' in record.keys():
                    if isinstance(record['outputs'], list) is False:
                        raise Exception('Resource specified invalid "outputs" value, expecting list value')
        except Exception as exception:
            pprint(record)
            raise exception

    @staticmethod
    def to_aws_ref(name, project=None, environment=None) -> str:
        """
        Convert name to an AWS reference name

        :type name: str
        :param name: The name to convert

        :type project: str
        :param project: Project being built (e.g. Rewards)

        :type environment: str
        :param environment: Environment being built (e.g. Dev)

        :return: string in ProjectEnvironmentX format
        """
        name = str(name)

        if CloudFormationBuilder.__references_convert_to_camel_case__ is False:
            return name

        if project is None or CloudFormationBuilder.__references_prefix_project__ is False:
            project = ''

        if environment is None or CloudFormationBuilder.__references_prefix_environment__ is False:
            environment = ''

        if CloudFormationBuilder.__references_convert_to_camel_case__ is True:
            environment_ref = environment.title().replace('-', ' ').replace('_', ' ').title().replace(' ', '')
            project_ref = project.title().replace('-', ' ').replace('_', ' ').title().replace(' ', '')
            name = name.replace('-', ' ').replace('_', ' ').title().replace(' ', '')
        else:
            environment_ref = environment
            project_ref = project

        return "{project_ref}{environment_ref}{name}".format(
            project_ref=project_ref,
            environment_ref=environment_ref,
            name=name
        )

    @staticmethod
    def to_snake(value, separator='-') -> str:
        """
        :type value: str
        :param value: String to convert

        :type separator: str
        :param separator: The separator to use

        :return: The input string converted to snake-case
        """
        s1 = re.sub('(.)([A-Z][a-z]+)', r'\1{separator}\2'.format(separator=separator), value)
        return re.sub('([a-z0-9])([A-Z])', r'\1{separator}\2', s1).format(separator=separator).lower()

    @staticmethod
    def to_camel(value, separator='-', include_first=True):
        """
        Convert 'dash-value' to 'CamelValue'

        :type value: str
        :param value:

        :type separator: str
        :param separator: The dashes used as separator

        :type include_first: bool
        :param include_first:

        :return: Camel case variant of string
        """
        components = value.split(separator)

        if include_first is True:
            return ''.join(x.title() for x in components)

        return components[0] + ''.join(x.title() for x in components[1:])


if __name__ == '__main__':

    def make_executable(path):
        mode = os.stat(path).st_mode
        mode |= (mode & 0o444) >> 2
        os.chmod(path, mode)

    timestamp_deploy = int(round(time.time() * 1000))

    parser = argparse.ArgumentParser(description='Build CloudFormation Template')
    parser.add_argument('--config', required=True, help="Build manifest file (JSON)")
    parser.add_argument('--environment', required=False, help="Build specific environment")
    parser.add_argument('--path-output', required=True, help="Output base path")
    args = parser.parse_args()

    config_file = open(args.config, 'rt')
    config = json.load(config_file)
    config_file.close()

    template_path=os.path.dirname(args.config)

    if 'Project' not in config:
        print("ERROR: Build manifest missing required 'Project' value")
        exit(1)

    project_id = config['Project']

    delegate_tags = ['Application', 'Infrastructure']

    for delegate_tag in delegate_tags:
        if delegate_tag in config:
            if 'AwsRegion' not in config:
                print("ERROR: Build manifest missing required 'AwsRegion' value")
                exit(1)

            if 'Environments' not in config[delegate_tag]:
                print("ERROR: Build manifest missing required '{delegate_tag}.Environments' value".format(delegate_tag=delegate_tag))
                exit(1)

            for environment_id, __environment__ in config[delegate_tag]['Environments'].items():
                if args.environment is not None and args.environment.lower() != environment_id.lower():
                    CloudFormationBuilder.debug_print("Skipping environment: {environment_id}".format(environment_id=environment_id))
                    continue

                path_output = "{path_output}/{environment_id}".format(path_output=args.path_output, environment_id=environment_id)
                path_tags = "{path_output}/Tags".format(path_output=path_output)
                path_templates = "{path_output}/Templates".format(path_output=path_output)

                os.makedirs(path_output, exist_ok=True)
                os.makedirs(path_tags, exist_ok=True)
                os.makedirs(path_templates, exist_ok=True)

                required_parameters = ['AwsAccountId', 'Templates']
                for parameter in required_parameters:
                    if parameter not in __environment__:
                        print("ERROR: Build manifest missing required '{delegate_tag}.Environment.{parameter}' value".format(
                            delegate_tag=delegate_tag,
                            parameter=parameter
                        ))
                        exit(1)

                # noinspection DuplicatedCode
                template_count = 1

                for template in __environment__['Templates']:

                    template_filename = "{template_path}/{environment_id}/{template}".format(
                        template_path=template_path,
                        environment_id=environment_id,
                        template=template
                    )

                    if os.path.exists(template_filename) is False:
                        print("ERROR: Template file specified in build manifest ({template_filename}) not found".format(template_filename=template_filename))
                        exit(1)

                    # Read the input file and process into a dictionary
                    file = open(template_filename, 'rt')
                    yaml_content = yaml.full_load(file)
                    file.close()

                    basename = os.path.splitext(os.path.basename(template))[0]

                    if CloudFormationBuilder.__references_prefix_project__ is False:
                        project_id_ref = ''
                    else:
                        project_id_ref = project_id

                    if CloudFormationBuilder.__references_prefix_environment__ is False:
                        environment_id_ref = ''
                    else:
                        environment_id_ref = environment_id

                    if 'stack_name' in yaml_content['template'].keys():
                        stack_name = yaml_content['template']['stack_name']
                    else:
                        stack_name = "{project_id}{environment_id}{basename}".format(
                            project_id=str(project_id_ref).title(),
                            environment_id=str(environment_id_ref).title(),
                            basename=basename
                        )

                    if 'stack_name_prefix_environment' in yaml_content['template'].keys():
                        if yaml_content['template']['stack_name_prefix_environment'] is True:
                            stack_name = '{prefix}{stack_name}'.format(
                                prefix=environment_id,
                                stack_name=stack_name
                            )

                    if 'stack_name_prefix_folder' in yaml_content['template'].keys():
                        if yaml_content['template']['stack_name_prefix_folder'] is True:
                            stack_name = '{prefix}{stack_name}'.format(
                                prefix=os.path.basename(os.path.dirname(template_filename)),
                                stack_name=stack_name
                            )

                    stack_name = '{project_id}{environment_id}{stack_name}'.format(
                        project_id=str(project_id_ref).title(),
                        environment_id=str(environment_id_ref).title(),
                        stack_name=stack_name
                    )

                    output_filename = "{path}/{template_count:03d}.{stack_name}.yml".format(
                        path=path_templates,
                        template_count=template_count,
                        stack_name=stack_name,
                    )
                    # Generate template for this environment
                    CloudFormationBuilder.debug_print('Building CloudFormation Template')
                    CloudFormationBuilder.debug_print('')
                    CloudFormationBuilder.debug_print('Project:                      {project_id}'.format(project_id=project_id))
                    CloudFormationBuilder.debug_print('Environment:                  {environment_id}'.format(environment_id=environment_id))
                    CloudFormationBuilder.debug_print('Delegate Tag:                 {delegate_tag}'.format(delegate_tag=delegate_tag))
                    CloudFormationBuilder.debug_print('AWS Account ID:               {aws_account_id}'.format(aws_account_id=__environment__['AwsAccountId']))
                    CloudFormationBuilder.debug_print('AWS Region:                   {aws_default_region}'.format(aws_default_region=config['AwsRegion']))
                    CloudFormationBuilder.debug_print('Template Configuration File:  {template_filename}'.format(template_filename=template_filename))
                    CloudFormationBuilder.debug_print('Compiled Template Filename:   {output_filename}'.format(output_filename=output_filename))

                    tags_filename = "{path_tags}/{template_count:03d}.{stack_name}.json".format(
                        path_tags=path_tags,
                        template_count=template_count,
                        stack_name=stack_name
                    )
                    CloudFormationBuilder.debug_print('Compiled Tag Filename:        {tags_filename}'.format(tags_filename=tags_filename))
                    CloudFormationBuilder.debug_print('')

                    CloudFormationBuilder.generate(
                        environment=environment_id,
                        project=CloudFormationBuilder.to_snake(project_id),
                        input_filename=template_filename,
                        output_filename=output_filename,
                        tags_filename=tags_filename,
                        aws_account_id=__environment__['AwsAccountId'],
                        aws_default_region=config['AwsRegion'],
                        service_definition=CloudFormationBuilder.to_snake(delegate_tag)
                    )

                    build_filename = os.path.basename(output_filename)
                    bucket_filename = "s3://artifacts.{service_id}.{project_id}.{environment_id}.eonx.com/{service_id_ref}/{timestamp}/{build_filename}".format(
                        project_id=CloudFormationBuilder.to_snake(project_id),
                        project_id_ref=CloudFormationBuilder.to_aws_ref(name=project_id),
                        service_id=CloudFormationBuilder.to_snake(delegate_tag),
                        service_id_ref=CloudFormationBuilder.to_aws_ref(name=delegate_tag),
                        environment_id=CloudFormationBuilder.to_snake(environment_id),
                        environment_id_ref=CloudFormationBuilder.to_aws_ref(name=environment_id),
                        build_filename=build_filename,
                        timestamp=timestamp_deploy
                    )

                    template_count += 1

                bucket_path = "s3://artifacts.{service_id}.{project_id}.{environment_id}.eonx.com/{service_id_ref}/{timestamp}".format(
                    project_id=CloudFormationBuilder.to_snake(project_id),
                    project_id_ref=CloudFormationBuilder.to_aws_ref(name=project_id),
                    service_id=CloudFormationBuilder.to_snake(delegate_tag),
                    service_id_ref=CloudFormationBuilder.to_aws_ref(name=delegate_tag),
                    environment_id=CloudFormationBuilder.to_snake(environment_id),
                    environment_id_ref=CloudFormationBuilder.to_aws_ref(name=environment_id),
                    timestamp=timestamp_deploy
                )

                if 'WebHook' in __environment__:
                    webhook = __environment__['WebHook']
                    if 'AccountId' not in webhook:
                        print("ERROR: Environment web hook configuration missing required 'AccountID' value")
                        exit(1)
                    if 'ApplicationId' not in webhook:
                        print("ERROR: Environment web hook configuration missing required 'ApplicationId' value")
                        exit(1)
                    if 'TriggerId' not in webhook:
                        print("ERROR: Environment web hook configuration missing required 'TriggerId' value")
                        exit(1)

                    webhook_data = {
                        'application': webhook['ApplicationId'],
                        'parameters': {
                            'Environment': str(environment_id).lower(),
                            'InfraDefinition_SSH': "{project_id}-{service_id}-{environment_id}".format(
                                project_id=CloudFormationBuilder.to_snake(project_id),
                                service_id=CloudFormationBuilder.to_snake(delegate_tag),
                                environment_id=CloudFormationBuilder.to_snake(environment_id)
                            ),
                            "IAM_ROLE_ARN": "arn:aws:iam::{aws_account_id}:role/{project_id_ref}{environment_id_ref}Harness{service_id_ref}DelegateIamRole".format(
                                aws_account_id=__environment__['AwsAccountId'],
                                project_id_ref=CloudFormationBuilder.to_aws_ref(name=project_id),
                                service_id_ref=CloudFormationBuilder.to_aws_ref(name=delegate_tag),
                                environment_id_ref=CloudFormationBuilder.to_aws_ref(name=environment_id)
                            ),
                            "AWS_ACCOUNT_ID": "{aws_account_id}".format(aws_account_id=__environment__['AwsAccountId']),
                            "AWS_DEFAULT_REGION": "{aws_default_region}".format(aws_default_region=config['AwsRegion']),
                            "SOURCE_S3_BUCKET": "artifacts.{service_id}.{project_id}.{environment_id}.eonx.com".format(
                                project_id=CloudFormationBuilder.to_snake(project_id),
                                project_id_ref=CloudFormationBuilder.to_aws_ref(name=project_id),
                                service_id=CloudFormationBuilder.to_snake(delegate_tag),
                                service_id_ref=CloudFormationBuilder.to_aws_ref(name=delegate_tag),
                                environment_id=CloudFormationBuilder.to_snake(environment_id),
                                environment_id_ref=CloudFormationBuilder.to_aws_ref(name=environment_id),
                                timestamp=timestamp_deploy
                            ),
                            "SOURCE_S3_PATH": "{service_id_ref}/{timestamp}".format(
                                project_id_ref=CloudFormationBuilder.to_aws_ref(name=project_id),
                                service_id_ref=CloudFormationBuilder.to_aws_ref(name=delegate_tag),
                                environment_id_ref=CloudFormationBuilder.to_aws_ref(name=environment_id),
                                timestamp=timestamp_deploy
                            )
                        }
                    }

