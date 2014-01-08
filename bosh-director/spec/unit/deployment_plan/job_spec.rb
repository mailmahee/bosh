require 'spec_helper'

describe Bosh::Director::DeploymentPlan::Job do
  subject(:job)    { described_class.new(plan, spec) }
  let(:plan)       { instance_double('Bosh::Director::DeploymentPlan::Planner', model: deployment) }
  let(:deployment) { Bosh::Director::Models::Deployment.make }

  let(:spec) do
    {
      'name' => 'foobar',
      'template' => 'foo',
      'release' => 'appcloud',
      'resource_pool' => 'dea'
    }
  end

  describe '#parse' do
    it 'parses all the parts' do
      [
        :parse_name,
        :parse_release,
        :parse_template,
        :parse_templates,
        :parse_disk,
        :parse_properties,
        :parse_resource_pool,
        :parse_update_config,
        :parse_instances,
        :parse_networks,
      ].each { |m| expect(job).to receive(m).with(no_args).ordered }
      job.parse
    end
  end

  describe 'parsing job spec' do
    describe 'name key' do
      it 'parses name' do
        job.parse_name
        expect(job.name).to eq('foobar')
      end
    end

    describe 'release key' do
      it 'parses release' do
        release = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion')
        allow(plan).to receive(:release).with('appcloud').and_return(release)
        job.parse_release
        expect(job.release).to eq(release)
      end

      it 'complains about unknown release' do
        allow(plan).to receive(:release).with('appcloud').and_return(nil)
        expect {
          job.parse_release
        }.to raise_error(Bosh::Director::JobUnknownRelease)
      end
    end

    describe 'template key' do
      it 'parses a single template' do
        release = instance_double(Bosh::Director::DeploymentPlan::ReleaseVersion)
        template = instance_double(Bosh::Director::DeploymentPlan::Template)

        allow(plan).to receive(:release).with('appcloud').and_return(release)
        expect(release).to receive(:use_template_named).with('foo')
        expect(release).to receive(:template).with('foo').and_return(template)

        job.parse_release
        job.parse_template
        expect(job.templates).to eq([template])
      end

      it 'parses multiple templates' do
        spec['template'] = %w(foo bar)
        release = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion')
        foo_template = instance_double('Bosh::Director::DeploymentPlan::Template')
        bar_template = instance_double('Bosh::Director::DeploymentPlan::Template')

        expect(plan).to receive(:release).with('appcloud').and_return(release)

        expect(release).to receive(:use_template_named).with('foo')
        expect(release).to receive(:use_template_named).with('bar')

        expect(release).to receive(:template).with('foo').and_return(foo_template)
        expect(release).to receive(:template).with('bar').and_return(bar_template)

        job.parse_release
        job.parse_template
        expect(job.templates).to eq([foo_template, bar_template])
      end
    end

    describe 'templates key' do
      context 'when value is an array of hashes' do
        context 'when one of the hashes specifies a release' do
          before do
            spec['templates'] = [{
              'name' => 'fake-template-name',
              'release' => 'fake-template-release',
            }]
          end

          let(:template_rel_ver) { instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion') }

          context 'when job specifies a release' do
            before { spec['release'] = 'fake-job-release' }

            it 'uses release specified in a hash' do
              expect(plan).to receive(:release)
                .with('fake-template-release')
                .and_return(template_rel_ver)

              template = instance_double('Bosh::Director::DeploymentPlan::Template')
              expect(template_rel_ver).to receive(:use_template_named)
                .with('fake-template-name')
                .and_return(template)

              job.parse_templates
              expect(job.templates).to eq([template])
            end
          end

          context 'when job does not specify a release' do
            before { spec.delete('release') }

            it 'uses release specified in a hash' do
              expect(plan).to receive(:release)
                .with('fake-template-release')
                .and_return(template_rel_ver)

              template = instance_double('Bosh::Director::DeploymentPlan::Template')
              expect(template_rel_ver).to receive(:use_template_named)
                .with('fake-template-name')
                .and_return(template)

              job.parse_templates
              expect(job.templates).to eq([template])
            end
          end
        end

        context 'when one of the hashes does not specify a release' do
          before { spec['templates'] = [{'name' => 'fake-template-name'}] }
          before { spec['release'] = 'fake-job-release' }

          it 'uses release parsed earlier via parse_release' do
            job_rel_ver = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion')
            allow(plan).to receive(:release)
              .with('fake-job-release')
              .and_return(job_rel_ver)

            job.parse_release

            template = instance_double('Bosh::Director::DeploymentPlan::Template')
            expect(job_rel_ver).to receive(:use_template_named)
              .with('fake-template-name')
              .and_return(template)

            job.parse_templates
            expect(job.templates).to eq([template])
          end
        end

        context 'when one of the hashes specifies a release not specified in a deployment' do
          before do
            spec['templates'] = [{
              'name' => 'fake-template-name',
              'release' => 'fake-template-release',
            }]
          end

          it 'raises an error because all referenced releases need to be specified under releases' do
            spec['name'] = 'fake-job-name'
            job.parse_name

            expect(plan).to receive(:release)
              .with('fake-template-release')
              .and_return(nil)

            expect {
              job.parse_templates
            }.to raise_error(
              Bosh::Director::JobUnknownRelease,
              "Template `fake-template-name' (job `fake-job-name') references an unknown release `fake-template-release'",
            )
          end
        end

        context 'when multiple hashes have the same name' do
          before do
            spec['templates'] = [
              {'name' => 'fake-template-name1'},
              {'name' => 'fake-template-name2'},
              {'name' => 'fake-template-name1'},
            ]
          end

          before do # resolve release and template objs
            spec['release'] = 'fake-job-release'

            job_rel_ver = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion')
            allow(plan).to receive(:release)
              .with('fake-job-release')
              .and_return(job_rel_ver)

            job.parse_release

            allow(job_rel_ver).to receive(:use_template_named) do |name|
              instance_double('Bosh::Director::DeploymentPlan::Template', name: name)
            end
          end

          it 'raises an error because job dirs on a VM will become ambiguous' do
            spec['name'] = 'fake-job-name'
            job.parse_name

            expect {
              job.parse_templates
            }.to raise_error(
              Bosh::Director::JobInvalidTemplates,
              "Job `fake-job-name' templates must not have repeating names."
            )
          end
        end

        context 'when multiple hashes reference different releases' do
          before do
            spec['templates'] = [
              {'name' => 'fake-template-name1', 'release' => 'fake-template-release1'},
              {'name' => 'fake-template-name2', 'release' => 'fake-template-release2'},
            ]
          end

          before do # resolve first release and template obj
            rel_ver1 = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion')
            allow(plan).to receive(:release)
              .with('fake-template-release1')
              .and_return(rel_ver1)

            template1 = instance_double(
              'Bosh::Director::DeploymentPlan::Template',
              name: 'fake-template-name1',
              release: rel_ver1,
            )
            allow(rel_ver1).to receive(:use_template_named)
              .with('fake-template-name1')
              .and_return(template1)
          end

          before do # resolve second release and template obj
            rel_ver2 = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion')
            allow(plan).to receive(:release)
              .with('fake-template-release2')
              .and_return(rel_ver2)

            template2 = instance_double(
              'Bosh::Director::DeploymentPlan::Template',
              name: 'fake-template-name2',
              release: rel_ver2,
            )
            allow(rel_ver2).to receive(:use_template_named)
              .with('fake-template-name2')
              .and_return(template2)
          end

          it 'raises an error because currently multi-release collocation is not supported' do
            spec['name'] = 'fake-job-name'
            job.parse_name

            expect {
              job.parse_templates
            }.to raise_error(
              Bosh::Director::JobInvalidTemplates,
              "Job `fake-job-name' templates must come from the same release."
            )
          end
        end

        context 'when one of the hashes is missing a name' do
          it 'raises an error because that is how template will be found' do
            spec['templates'] = [{}]
            expect {
              job.parse_templates
            }.to raise_error(
              Bosh::Director::ValidationMissingField,
              %{Required property `name' was not specified in object ({})},
            )
          end
        end

        context 'when one of the elements is not a hash' do
          it 'raises an error' do
            spec['templates'] = ['not-a-hash']
            expect {
              job.parse_templates
            }.to raise_error(
              Bosh::Director::ValidationInvalidType,
              %{Object ("not-a-hash") did not match the required type `Hash'},
            )
          end
        end
      end

      context 'when value is not an array' do
        it 'raises an error' do
          spec['templates'] = 'not-an-array'
          expect {
            job.parse_templates
          }.to raise_error(
            Bosh::Director::ValidationInvalidType,
            %{Property `templates' (value "not-an-array") did not match the required type `Array'},
          )
        end
      end
    end

    describe 'persistent_disk key' do
      it 'parses persistent disk if present' do
        spec['persistent_disk'] = 300
        job.parse_disk
        expect(job.persistent_disk).to eq(300)
      end

      it 'uses 0 for persistent disk if not present' do
        job.parse_disk
        expect(job.persistent_disk).to eq(0)
      end
    end

    describe 'resource_pool key' do
      it 'parses resource pool' do
        resource_pool = instance_double('Bosh::Director::DeploymentPlan::ResourcePool')
        expect(plan).to receive(:resource_pool).with('dea').and_return(resource_pool)
        job.parse_resource_pool
        expect(job.resource_pool).to eq(resource_pool)
      end

      it 'complains about unknown resource pool' do
        expect(plan).to receive(:resource_pool).with('dea').and_return(nil)
        expect {
          job.parse_resource_pool
        }.to raise_error(Bosh::Director::JobUnknownResourcePool)
      end
    end

    describe 'binding properties' do
      let(:props) do
        {
          'cc_url' => 'www.cc.com',
          'deep_property' => {
            'unneeded' => 'abc',
            'dont_override' => 'def'
          },
          'dea_max_memory' => 1024
        }
      end

      let(:foo_properties) do
        {
          'dea_min_memory' => {'default' => 512},
          'deep_property.dont_override' => {'default' => 'ghi'},
          'deep_property.new_property' => {'default' => 'jkl'}
        }
      end

      let(:bar_properties) do
        {'dea_max_memory' => {'default' => 2048}}
      end

      before do
        spec['properties'] = props
        spec['template'] = %w(foo bar)

        release = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion')

        allow(plan).to receive(:properties).and_return(props)
        expect(plan).to receive(:release).with('appcloud').and_return(release)

        expect(release).to receive(:use_template_named).with('foo')
        expect(release).to receive(:use_template_named).with('bar')

        expect(release).to receive(:template).with('foo').and_return(foo_template)
        expect(release).to receive(:template).with('bar').and_return(bar_template)

        job.parse_name
        job.parse_release
        job.parse_template
        job.parse_properties
      end

      context 'when all the job specs (aka templates) specify properties' do
        let(:foo_template) do
          instance_double('Bosh::Director::DeploymentPlan::Template', properties: foo_properties)
        end

        let(:bar_template) do
          instance_double('Bosh::Director::DeploymentPlan::Template', properties: bar_properties)
        end

        before { job.bind_properties }

        it 'should drop deployment manifest properties not specified in the job spec properties' do
          expect(job.properties).to_not have_key('cc')
          expect(job.properties['deep_property']).to_not have_key('unneeded')
        end

        it 'should include properties that are in the job spec properties but not in the deployment manifest' do
          expect(job.properties['dea_min_memory']).to eq(512)
          expect(job.properties['deep_property']['new_property']).to eq('jkl')
        end

        it 'should not override deployment manifest properties with job_template defaults' do
          expect(job.properties['dea_max_memory']).to eq(1024)
          expect(job.properties['deep_property']['dont_override']).to eq('def')
        end
      end

      context 'when none of the job specs (aka templates) specify properties' do
        let(:foo_template) {
          instance_double('Bosh::Director::DeploymentPlan::Template', properties: nil) }
        let(:bar_template) {
          instance_double('Bosh::Director::DeploymentPlan::Template', properties: nil) }

        before { job.bind_properties }

        it 'should use the properties specified throughout the deployment manifest' do
          expect(job.properties).to eq(props)
        end
      end

      context "when some job specs (aka templates) specify properties and some don't" do
        let(:foo_template) {
          instance_double('Bosh::Director::DeploymentPlan::Template', properties: nil)
        }
        let(:bar_template) {
          instance_double('Bosh::Director::DeploymentPlan::Template', properties: bar_properties)
        }

        it 'should raise an error' do
          expect {
            job.bind_properties
          }.to raise_error(
            Bosh::Director::JobIncompatibleSpecs,
            "Job `foobar' has specs with conflicting property definition styles" +
            ' between its job spec templates.  This may occur if colocating jobs, one of which has a spec file' +
            " including `properties' and one which doesn't."
          )
        end
      end
    end

    describe 'property mappings' do
      it 'supports property mappings' do
        props = {
          'ccdb' => {
            'user' => 'admin',
            'password' => '12321',
            'unused' => 'yada yada'
          },
          'dea' => {
            'max_memory' => 2048
          }
        }

        spec['properties'] = props
        spec['property_mappings'] = {'db' => 'ccdb', 'mem' => 'dea.max_memory'}
        spec['template'] = 'foo'

        release = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion')
        foo_template = instance_double(
          'Bosh::Director::DeploymentPlan::Template',
          properties: {
            'db.user' => { 'default' => 'root' },
            'db.password' => {},
            'db.host' => { 'default' => 'localhost' },
            'mem' => { 'default' => 256 },
          },
        )

        allow(plan).to receive(:properties).and_return(props)
        expect(plan).to receive(:release).with('appcloud').and_return(release)

        expect(release).to receive(:template).with('foo').and_return(foo_template)
        expect(release).to receive(:use_template_named).with('foo')

        job.parse_release
        job.parse_template
        job.parse_properties
        job.bind_properties

        expect(job.properties).to eq(
          'db' => {
            'user' => 'admin',
            'password' => '12321',
            'host' => 'localhost'
          },
          'mem' => 2048,
        )
      end

      it 'complains about unsatisfiable property mappings' do
        props = {'foo' => 'bar'}

        spec['properties'] = props
        spec['property_mappings'] = {'db' => 'ccdb'}

        allow(plan).to receive(:properties).and_return(props)

        expect {
          job.parse_properties
        }.to raise_error(Bosh::Director::JobInvalidPropertyMapping)
      end
    end
  end
end
