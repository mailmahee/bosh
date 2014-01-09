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

  describe '#bind_properties' do
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

    context 'when all the templates specify properties' do
      let(:foo_template) { instance_double('Bosh::Director::DeploymentPlan::Template', properties: foo_properties) }
      let(:bar_template) { instance_double('Bosh::Director::DeploymentPlan::Template', properties: bar_properties) }

      it 'should drop deployment manifest properties not specified in the job spec properties' do
        job.bind_properties
        expect(job.properties).to_not have_key('cc')
        expect(job.properties['deep_property']).to_not have_key('unneeded')
      end

      it 'should include properties that are in the job spec properties but not in the deployment manifest' do
        job.bind_properties
        expect(job.properties['dea_min_memory']).to eq(512)
        expect(job.properties['deep_property']['new_property']).to eq('jkl')
      end

      it 'should not override deployment manifest properties with job_template defaults' do
        job.bind_properties
        expect(job.properties['dea_max_memory']).to eq(1024)
        expect(job.properties['deep_property']['dont_override']).to eq('def')
      end
    end

    context 'when none of the job specs (aka templates) specify properties' do
      let(:foo_template) { instance_double('Bosh::Director::DeploymentPlan::Template', properties: nil) }
      let(:bar_template) { instance_double('Bosh::Director::DeploymentPlan::Template', properties: nil) }

      it 'should use the properties specified throughout the deployment manifest' do
        job.bind_properties
        expect(job.properties).to eq(props)
      end
    end

    context "when some job specs (aka templates) specify properties and some don't" do
      let(:foo_template) { instance_double('Bosh::Director::DeploymentPlan::Template', properties: nil) }
      let(:bar_template) { instance_double('Bosh::Director::DeploymentPlan::Template', properties: bar_properties) }

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

  end
end
