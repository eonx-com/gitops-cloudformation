#!/usr/bin/env python3

import argparse
import base64
import json
import os
import re
import secrets
import time
import yaml

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
    __records__ = None

    @staticmethod
    def debug_print(message=''):
        if CloudFormationBuilder.__debug_output__ is True:
            print(message)

    @staticmethod
    def clear() -> None:
        """
        Clear all loaded templates
        """
        CloudFormationBuilder.__records__ = {
            'resource': {},
            'parameter': {},
            'output': {}
        }

    @staticmethod
    def load(input_filename) -> None:
        """
        Load template into storage for later rendering

        :type input_filename: str
        :param input_filename: The input templates filename
        """
        # Make sure the input filename can be found
        if os.path.exists(input_filename) is False:
            raise Exception('The specified input filename ({input_filename}) does not exists'.format(input_filename=input_filename))

        # Read the input file and process into a dictionary
        template_file = open(input_filename, 'rt')
        template_yaml = yaml.full_load(template_file)
        template_file.close()

        print("\t- {input_filename}".format(input_filename=input_filename))

        # Iterate all records and record the details of items we need to create
        for record_id, record in template_yaml.items():
            # Validate the record
            CloudFormationBuilder.validate_record(record)

            # If the record outputs were requested, add that as well (along with the record they relate to)
            if '_outputs' in record.keys():
                for output in record['_outputs']:
                    output['_record_id'] = record_id

                    output_required_parameters = ['_ref', '_description', '_name']
                    for output_parameter in output_required_parameters:
                        if output_parameter not in output.keys():
                            print(output.keys())
                            print('ERROR: Missing required output key "{output_parameter}"'.format(output_parameter=output_parameter))
                            exit(1)

                    CloudFormationBuilder.__records__['output'][output['_name']] = {
                        'record': record,
                        'record_id': record_id,
                        'output': output
                    }

            if '_tags' in record:
                if record['_tags'] is True:
                    if 'properties' not in record:
                        record['properties'] = {}
                    if 'Tags' not in record['Properties']:
                        record['Properties']['Tags'] = []

                    # Add a name tag for the resource
                    record['Properties']['Tags'].append({
                        'Key': 'Name',
                        'Value': record_id
                    })

            # Store the record for later rendering
            rendered_record = {}
            for key in record.keys():
                if str(key).startswith('_') is False:
                    rendered_record[key] = record[key]

            CloudFormationBuilder.__records__[record['_type']][record_id] = rendered_record

    @staticmethod
    def render(environment, project, description) -> str:
        """
        Render CloudFormation template using previously loaded templates

        :param environment: Environment name
        :param project: Project Name
        :param description: Stack Description

        :return: Rendered YAML
        """
        CloudFormationBuilder.__environment__ = environment
        CloudFormationBuilder.__project__ = project

        rendered = 'AWSTemplateFormatVersion: "2010-09-09"\n'
        rendered += 'Description: {description}\n'.format(description=description)

        rendered += '\n'
        rendered += '# ----------------------------------------------------------------------------------------\n'
        rendered += '# STACK METADATA\n'
        rendered += '# ----------------------------------------------------------------------------------------\n'
        rendered += '\n'
        rendered += 'Metadata:\n'
        rendered += '\n'
        rendered += '  Project: {project}\n'.format(project=CloudFormationBuilder.to_camel(project))
        rendered += '  Environment: {environment}\n'.format(environment=CloudFormationBuilder.to_camel(environment))

        # Render stack parameters
        if len(CloudFormationBuilder.__records__['parameter']) > 0:
            CloudFormationBuilder.debug_print('Creating Stack Parameters')
            CloudFormationBuilder.debug_print()
            rendered += '\n'
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '# STACK PARAMETERS\n'
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '\n'
            rendered += 'Parameters:\n'
            for stack_parameter_id, stack_parameter in CloudFormationBuilder.__records__['parameter'].items():
                rendered += CloudFormationBuilder.render_value(stack_parameter_id, stack_parameter)
            CloudFormationBuilder.debug_print()

        # Render stack resources
        if len(CloudFormationBuilder.__records__['resource']) > 0:
            CloudFormationBuilder.debug_print('Creating Stack Resources')
            CloudFormationBuilder.debug_print()
            rendered += '\n'
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '# STACK RESOURCES\n'
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '\n'
            rendered += 'Resources:\n'

            for resource_id, resource in CloudFormationBuilder.__records__['resource'].items():
                rendered += CloudFormationBuilder.render_value(resource_id, resource)

            CloudFormationBuilder.debug_print()

        # Render stack outputs
        if len(CloudFormationBuilder.__records__['output']) > 0:
            CloudFormationBuilder.debug_print('Creating Stack Outputs')
            CloudFormationBuilder.debug_print()
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '# STACK OUTPUTS\n'
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '\n'
            rendered += 'Outputs:\n'
            rendered += '\n'
            for key, value in CloudFormationBuilder.__records__['output'].items():
                output = value['output']

                rendered += '  {output_name}:\n'.format(output_name=output['_name'])

                if isinstance(output['_ref'], dict) is True:
                    rendered += '    Value: {output_dict}\n'.format(output_dict=CloudFormationBuilder.render_dict(output['_ref'], indent=2))
                    if isinstance(output['_ref'], list) is True:
                        rendered += '    Value: {output_list}\n'.format(output_list=CloudFormationBuilder.render_list(output['_ref'], indent=2))
                else:
                    rendered += '    Value: {output_ref}\n'.format(output_ref=output['_ref'])

                rendered += '    Description: {output_description}\n'.format(output_description=output['_description'])
                rendered += '    Export:\n'
                rendered += '      Name: {output_name}\n'.format(output_name=output['_name'])

            CloudFormationBuilder.debug_print()

        # Remove all blank lines from template output
        rendered_split = rendered.split('\n')
        rendered = ''
        for line in rendered_split:
            if len(line.strip()) > 0:
                rendered += line + '\n'

        return rendered

    @staticmethod
    def render_value(name, value) -> str:
        parameter_aws_ref = name

        CloudFormationBuilder.debug_print('\t - {parameter_aws_ref}'.format(parameter_aws_ref=parameter_aws_ref))

        rendered = '\n'

        if 'title' in value:
            rendered += '  # ----------------------------------------------------------------------------------------\n'
            rendered += '  # {title}\n'.format(title=value['title'])
            rendered += '  # ----------------------------------------------------------------------------------------\n'
            rendered += '\n'

        if '_comment' in value:
            rendered += '  # {comment}\n'.format(comment=value['_comment'])

        rendered += '  {parameter_aws_ref}:\n'.format(parameter_aws_ref=parameter_aws_ref)

        for config_key, config_value in value.items():
            name = config_key

            if isinstance(config_value, list):
                value = CloudFormationBuilder.render_list(config_value, indent=2)
            elif isinstance(config_value, dict):
                value = CloudFormationBuilder.render_dict(config_value, indent=2)
            else:
                value = ' {config_value}'.format(config_value=config_value)

            rendered += '    {key}:{value}\n'.format(key=name, value=value)

        return rendered

    @staticmethod
    def render_list(value, indent=0, newline=True):
        output = ''
        for item in value:
            if newline is True:
                output += '\n'
                for i in range(0, indent):
                    output += '  '

            newline = True

            output += '  -'

            if isinstance(item, list):
                output += CloudFormationBuilder.render_list(item, indent + 1, newline=False)
            elif isinstance(item, dict):
                output += CloudFormationBuilder.render_dict(item, indent + 1, newline=False)
            else:
                output += ' {item}\n'.format(item=item)

        return output

    @staticmethod
    def render_dict(value, indent=0, newline=True):
        rendered = ' '

        if '_type' in value.keys():
            # AWS reference
            value_type = value['_type']
            if value_type.lower() == 'self':
                # Reference to self
                rendered += '!Ref {output_ref}'.format(output_ref=value['_record_id'])
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
                    rendered += CloudFormationBuilder.render_list(item, indent, newline=False)
                elif isinstance(item, dict):
                    rendered += CloudFormationBuilder.render_dict(item, indent, newline=False)
                else:
                    rendered += '{item}'.format(item=item)

            if value_type.lower() == 'ref':
                # Reference to another resource in same stack
                rendered += '!Ref {id}'.format(
                    id=value['_id']
                )
            elif value_type.lower() == 'depends-on':
                # Depends on reference
                rendered += '{id}'.format(id=value['_id'])
            elif value_type.lower() == 'importvalue_origin_access_identity_id':
                # Depends on reference
                indent = ''

                if '_indent' in value:
                    for i in range(0, value['_indent']):
                        indent += '  '

                rendered += '!Join\n{indent}- "/"\n{indent}- - "origin-access-identity/cloudfront"\n{indent}  - !ImportValue {id}'.format(
                    indent=indent,
                    id=value['_id']
                )
            elif value_type.lower() == 'importvalue_origin_access_identity_iam_user':
                # Depends on reference
                indent = ''

                if '_indent' in value:
                    for i in range(0, value['_indent']):
                        indent += '  '

                rendered += '!Join\n{indent}- "/"\n{indent}- - "arn:aws:iam::cloudfront:user"\n{indent}  - !ImportValue {id}'.format(
                    indent=indent,
                    id=value['_id']
                )
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
                    id=value['_id'],
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
                    if isinstance(item, list):
                        rendered_value = CloudFormationBuilder.render_list(item, value['_indent'] + 1, newline=False)
                    elif isinstance(item, dict):
                        rendered_value = CloudFormationBuilder.render_dict(item, value['_indent'] + 1, newline=False)
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
                    elif value['_case'].lower() == 'snake':
                        rendered += CloudFormationBuilder.to_snake(str(environment_id), '_')
                    elif value['_case'].lower() == 'snake-hyphen':
                        rendered += CloudFormationBuilder.to_snake(str(environment_id))
                    elif value['_case'].lower() == 'upper':
                        rendered += str(environment_id).upper()
                    elif value['_case'].lower() == 'title':
                        rendered += str(environment_id).title()
                    else:
                        rendered += str(environment_id)
                else:
                    rendered += str(environment_id)
            elif value_type.lower() == 'project-dash-environment':
                if '_case' in value.keys():
                    if value['_case'].lower() == 'lower':
                        rendered += str(project_id).lower() + '_' + str(environment_id).lower()
                    elif value['_case'].lower() == 'snake':
                        rendered += CloudFormationBuilder.to_snake(str(project_id), '_') + '_' + CloudFormationBuilder.to_snake(str(environment_id), '_')
                    elif value['_case'].lower() == 'snake-hyphen':
                        rendered += CloudFormationBuilder.to_snake(str(project_id)) + '_' + CloudFormationBuilder.to_snake(str(environment_id))
                    elif value['_case'].lower() == 'upper':
                        rendered += str(project_id).upper() + '_' + str(environment_id).upper()
                    elif value['_case'].lower() == 'title':
                        rendered += str(project_id).title() + '_' + str(environment_id).title()
                    else:
                        rendered += str(project_id) + '_' + str(environment_id)
                else:
                    rendered += str(environment_id)
            elif value_type.lower() == 'project':
                if '_case' in value.keys():
                    if value['_case'].lower() == 'lower':
                        rendered += str(project_id).lower()
                    elif value['_case'].lower() == 'snake':
                        rendered += CloudFormationBuilder.to_snake(str(project_id), '_')
                    elif value['_case'].lower() == 'snake-hyphen':
                        rendered += CloudFormationBuilder.to_snake(str(project_id))
                    elif value['_case'].lower() == 'upper':
                        rendered += str(project_id).upper()
                    elif value['_case'].lower() == 'title':
                        rendered += str(project_id).title()
                    else:
                        rendered += str(project_id)
                else:
                    rendered += str(project_id)
            elif value_type.lower() == 'importvalue':
                rendered += '!ImportValue {id}'.format(id=value['_id'])
        else:
            for record_id, record in value.items():
                # Boring old dictionary

                if newline is True:
                    rendered += '\n'
                    for i in range(0, indent + 1):
                        rendered += '  '

                rendered += '{id}:'.format(id=record_id)

                if isinstance(record, list):
                    rendered += CloudFormationBuilder.render_list(record, indent + 1)
                elif isinstance(record, dict):
                    rendered += CloudFormationBuilder.render_dict(record, indent + 1)
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
            if '_type' not in record.keys():
                print(record.keys())
                raise Exception('Invalid YAML configuration, missing required "type" key')

            record_type = record['_type']

            # Make sure record type is known
            if record_type not in ['parameter', 'resource']:
                raise Exception('Unknown record type specified')

            if record_type == '_tags':
                if isinstance(record, dict) is False:
                    raise Exception('Invalid data type for "tags" key, expected dictionary')
                for key, value in record.items():
                    if isinstance(value, dict) is True or isinstance(value, list) is True:
                        raise Exception('Invalid data type for "tags" key, values must be a scalar type')
        except Exception as exception:
            raise exception

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

    try:
        config_file = open(args.config, 'rt')
        config = json.load(config_file)
        config_file.close()
    except Exception as json_load_exception:
        try:
            config_file = open(args.config, 'rt')
            config = yaml.full_load(config_file)
            config_file.close()
        except Exception as yaml_load_exception:
            print('ERROR: Could not parse configuration file')
            print(json_load_exception)
            print(yaml_load_exception)

    template_path = os.path.dirname(args.config)

    if 'Project' not in config:
        print("ERROR: Build manifest missing required 'Project' value")
        exit(1)

    project_id = config['Project']

    delegate_tags = ['Application', 'Infrastructure']

    print('Generating CloudFormation Templates')

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

                required_parameters = ['AwsAccountId', 'Stacks']
                for parameter in required_parameters:
                    if parameter not in __environment__:
                        print("ERROR: Build manifest missing required '{delegate_tag}.Environment.{parameter}' value".format(
                            delegate_tag=delegate_tag,
                            parameter=parameter
                        ))
                        exit(1)

                # noinspection DuplicatedCode
                template_count = 1

                for stack in __environment__['Stacks']:
                    CloudFormationBuilder.clear()

                    required_parameters = ['Templates', 'Name', 'Description']
                    for parameter in required_parameters:
                        if parameter not in stack.keys():
                            print("ERROR: Stack missing missing required '{parameter}' value".format(parameter=parameter))
                            exit(1)

                    output_filename = "{path}/{template_count:03d}.{stack_name}.yml".format(
                        path=path_templates,
                        template_count=template_count,
                        stack_name=stack['Name'],
                    )

                    print()
                    print('Building Template: {output_filename}'.format(output_filename=output_filename))
                    print()

                    tags_filename = "{path_tags}/{template_count:03d}.{stack_name}.json".format(
                        path_tags=path_tags,
                        template_count=template_count,
                        stack_name=stack['Name']
                    )

                    templates = stack['Templates']

                    for template_input_filename in templates:
                        template_filename = "{template_path}/{environment_id}/{template_input_filename}".format(
                            template_path=template_path,
                            environment_id=environment_id,
                            template_input_filename=template_input_filename
                        )
                        CloudFormationBuilder.load(template_filename)

                    rendered = CloudFormationBuilder.render(
                        environment=environment_id,
                        project=CloudFormationBuilder.to_snake(project_id),
                        description=stack['Description']
                    )

                    output_file = open(output_filename, 'wt')
                    output_file.write(rendered)
                    output_file.close()

                    template_count += 1
