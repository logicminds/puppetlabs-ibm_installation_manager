require 'spec_helper'

describe Puppet::Type.type("ibm_pkg").provider(:imcl) do
  let (:provider) { subject }
  let(:properties) do
    {
      :name       => 'test',
      :ensure     => 'present',
      :package    => 'com.ibm.websphere.NDTRIAL.v85',
      :version    => '8.5.5000.20130514_1044',
      :target     => '/opt/IBM/WebSphere/AppServer',
      :repository => '/vagrant/ibm/was/repository.config',
    }
  end
  let(:resource) { provider.new(properties) }

  it 'should return an array of instances' do
    expect(provider.instances).to be_instance_of instance_of?(Array)
  end

  # describe 'getter property methods' do
  #   it "should return value for ensure property" do
  #     expect(resource.ensure).to eq(nil)
  #   end
  # end
  #
  # describe 'setter property methods' do
  #   it "should allow setting of value for ensure property" do
  #     resource.ensure = 'value1'
  #     expect(resource.ensure).to eq('value1')
  #   end
  # end
end
