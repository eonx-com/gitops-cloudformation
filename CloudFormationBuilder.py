#!/usr/bin/env python3

import base64
import json
import os
import re
import sys
import yaml

from datetime import datetime
from pprint import pprint


class CloudFormationBuilder:
    templates = {}
    environment = ''
    project = ''

    @staticmethod
    def generate(input_filename, output_filename) -> None:
        """
        Generate output template

        :type input_filename: str
        :param input_filename: The input filename

        :type output_filename: str
        :param output_filename: The output filename
        """
        # Make sure the input filename can be found
        if os.path.exists(input_filename) is False:
            raise Exception('The specified input filename ({input_filename}) does not exists'.format(input_filename=input_filename))

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
        required_keys = ['project', 'environment', 'description', 'category', 'author_name', 'author_email', 'account', 'region']
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

        created = datetime.now().isoformat()

        rendered += '\n'
        rendered += '# ----------------------------------------------------------------------------------------\n'
        rendered += '# STACK METADATA\n'
        rendered += '# ----------------------------------------------------------------------------------------\n'
        rendered += '\n'
        rendered += 'Metadata:\n'
        rendered += '\n'
        rendered += '  Created: {created}\n'.format(created=created)
        rendered += '  Account: {account}\n'.format(account=template['account'])
        rendered += '  Region: {region}\n'.format(region=template['region'])
        rendered += '  AuthorName: {author_name}\n'.format(author_name=template['author_name'])
        rendered += '  AuthorEmail: {author_email}\n'.format(author_email=template['author_email'])
        rendered += '  Category: {category}\n'.format(category=template['category'])
        rendered += '  Environment: {environment}\n'.format(environment=template['environment'])
        rendered += '  Project: {project}\n'.format(project=template['project'])

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
            print('Creating Stack Parameters')
            print()
            rendered += '\n'
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '# STACK PARAMETERS\n'
            rendered += '# ----------------------------------------------------------------------------------------\n'
            rendered += '\n'
            rendered += 'Parameters:\n'
            for parameter_id, parameter in records['parameter'].items():
                rendered += CloudFormationBuilder.render_value(template, parameter_id, parameter)
            print()

        # Render stack resources
        if len(records['resource']) > 0:
            print('Creating Stack Resources')
            print()
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
                            'Key': 'Created',
                            'Value': datetime.now().isoformat()
                        })

                        resource['config']['properties']['tags'].append({
                            'Key': 'Name',
                            'Value': CloudFormationBuilder.to_aws_ref(
                                name=resource_id,
                                project=template['project'],
                                environment=template['environment']
                            )
                        })

                        for key, value in template.items():
                            resource['config']['properties']['tags'].append({
                                'Key': CloudFormationBuilder.to_aws_ref(key),
                                'Value': value
                            })

                rendered += CloudFormationBuilder.render_value(template, resource_id, resource)

            print()

        # Render stack outputs
        if len(records['output']) > 0:
            print('Creating Stack Outputs')
            print()
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
                        environment=template['environment'],
                        project=template['project']
                    )
                else:
                    output_id = CloudFormationBuilder.to_aws_ref(
                        name=key,
                        environment=template['environment'],
                        project=template['project']
                    )

                print('\t- {output_id}'.format(output_id=output_id))

                output_value = CloudFormationBuilder.render_dict(template, output, indent=2)

                rendered += '  {output_id}:\n'.format(output_id=output_id)
                rendered += '    Value: {output_value}\n'.format(output_value=output_value)

                if '_description' in output:
                    rendered += '    Description: {description}\n'.format(description=output['_description'])

                rendered += '    Export:\n'
                rendered += '      Name: {output_id}\n'.format(output_id=output_id)

            print()

        # Remove all blank lines from template output
        rendered_split = rendered.split('\n')
        rendered = ''
        for line in rendered_split:
            if len(line.strip()) > 0:
                rendered += line + '\n'

        print('Saving Template: {output_filename} ({bytes} Bytes)'.format(output_filename=output_filename, bytes=len(rendered)))
        print()

        # Write output file to disk
        file = open(output_filename, 'wt')
        file.write(rendered)
        file.close()

        # Write tag string to file for CLI stack operations
        tags_filename = '{output_filename}.tags'.format(output_filename=output_filename)
        print('Saving Tag File: {tags_filename}'.format(tags_filename=tags_filename))

        tags = [
            {'Key': 'Created', 'Value': str(created)},
            {'Key': 'Account', 'Value': str(template['account'])},
            {'Key': 'Region', 'Value': template['region']},
            {'Key': 'AuthorName', 'Value': template['author_name']},
            {'Key': 'AuthorEmail', 'Value': template['author_email']},
            {'Key': 'Category', 'Value': template['category']},
            {'Key': 'Environment', 'Value': template['environment']},
            {'Key': 'Project', 'Value': template['project']}
        ]

        file = open(tags_filename, 'wt')
        file.write(json.dumps(tags))
        file.close()

    @staticmethod
    def render_value(template, name, value) -> str:
        parameter_aws_ref = CloudFormationBuilder.to_aws_ref(
            name=name,
            project=template['project'],
            environment=template['environment']
        )
        print('\t - {parameter_aws_ref}'.format(parameter_aws_ref=parameter_aws_ref))

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
                        environment=template['environment'],
                        project=template['project']
                    )
                )
            if value_type.lower() == 'ref':
                # Reference to another resource in same stack
                rendered += '!Ref {id}'.format(
                    id=CloudFormationBuilder.to_aws_ref(
                        name=value['_id'],
                        project=template['project'],
                        environment=template['environment']
                    )
                )
            elif value_type.lower() == 'depends-on':
                # Depends on reference
                rendered += '{id}'.format(
                    id=CloudFormationBuilder.to_aws_ref(
                        name=value['_id'],
                        project=template['project'],
                        environment=template['environment']
                    )
                )
            elif value_type.lower() == 'origin_access_identity_id':
                # Depends on reference
                indent = ''

                if '_indent' in value:
                    for i in range(0, value['_indent']):
                        indent += '  '

                rendered += '!Join\n{indent}- "/"\n{indent}- - "origin-access-identity/cloudfront"\n{indent}  - !Ref {id}'.format(
                    indent=indent,
                    id=CloudFormationBuilder.to_aws_ref(
                        name=value['_id'],
                        project=template['project'],
                        environment=template['environment']
                    )
                )
            elif value_type.lower() == 'camel-prefixed':
                # ProjectEnvironmentXXX prefixed name
                rendered += CloudFormationBuilder.to_aws_ref(
                    name=value['_value'],
                    project=template['project'],
                    environment=template['environment']
                )
            elif value_type.lower() == 'snake-prefixed':
                # project-environment-xxx prefixed name
                rendered += CloudFormationBuilder.to_snake(CloudFormationBuilder.to_aws_ref(
                    name=value['_value'],
                    project=template['project'],
                    environment=template['environment']
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
                        project=template['project'],
                        environment=template['environment']
                    ),
                    attribute=value['_attribute']
                )
            elif value_type.lower() == 'importvalue':
                rendered += '!ImportValue {id}'.format(
                    id=CloudFormationBuilder.to_aws_ref(
                        name=value['_id'],
                        project=template['project'],
                        environment=template['environment']
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
        if project is None:
            project = ''
        project_ref = project.title()

        if environment is None:
            environment = ''
        environment_ref = environment.title()

        if isinstance(name, str):
            name = name.replace('-', ' ').replace('_', ' ').title().replace(' ', '')

        return "{project}{environment}{name}".format(
            environment=environment_ref.replace('-', ' ').replace('_', ' ').title().replace(' ', ''),
            project=project_ref.replace('-', ' ').replace('_', ' ').title().replace(' ', ''),
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
    CloudFormationBuilder.generate(input_filename=sys.argv[1], output_filename=sys.argv[2])
