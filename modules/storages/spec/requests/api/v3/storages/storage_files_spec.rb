#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) 2012-2023 the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require 'spec_helper'
require_module_spec_helper

RSpec.describe 'API v3 storage files', content_type: :json, webmock: true do
  include API::V3::Utilities::PathHelper
  include StorageServerHelpers

  let(:permissions) { %i(view_work_packages view_file_links) }
  let(:project) { create(:project) }

  let(:current_user) do
    create(:user, member_in_project: project, member_with_permissions: permissions)
  end

  let(:oauth_application) { create(:oauth_application) }
  let(:storage) { create(:storage, creator: current_user, oauth_application:) }
  let(:project_storage) { create(:project_storage, project:, storage:) }

  let(:authorize_url) { 'https://example.com/authorize' }
  let(:connection_manager) { instance_double(OAuthClients::ConnectionManager) }

  subject(:last_response) do
    get path
  end

  before do
    allow(connection_manager).to receive(:get_authorization_uri).and_return(authorize_url)
    allow(connection_manager).to receive(:authorization_state).and_return(:connected)
    allow(OAuthClients::ConnectionManager).to receive(:new).and_return(connection_manager)
    project_storage
    login_as current_user
  end

  describe 'GET /api/v3/storages/:storage_id/files' do
    let(:path) { api_v3_paths.storage_files(storage.id) }

    let(:response) do
      Storages::StorageFiles.new(
        [
          Storages::StorageFile.new(
            id: 1,
            name: 'new_younglings.md',
            size: 4096,
            mime_type: 'text/markdown',
            created_at: DateTime.now,
            last_modified_at: DateTime.now,
            created_by_name: 'Obi-Wan Kenobi',
            last_modified_by_name: 'Obi-Wan Kenobi',
            location: '/',
            permissions: %i[readable]
          ),
          Storages::StorageFile.new(
            id: 2,
            name: 'holocron_inventory.md',
            size: 4096,
            mime_type: 'text/markdown',
            created_at: DateTime.now,
            last_modified_at: DateTime.now,
            created_by_name: 'Obi-Wan Kenobi',
            last_modified_by_name: 'Obi-Wan Kenobi',
            location: '/',
            permissions: %i[readable writeable]
          )
        ],
        Storages::StorageFile.new(
          id: 32,
          name: '/',
          size: 4096 * 2,
          mime_type: 'application/x-op-directory',
          created_at: DateTime.now,
          last_modified_at: DateTime.now,
          created_by_name: 'Obi-Wan Kenobi',
          last_modified_by_name: 'Obi-Wan Kenobi',
          location: '/',
          permissions: %i[readable writeable]
        ),
        []
      )
    end

    context 'with successful response' do
      before do
        storage_requests = instance_double(Storages::Peripherals::StorageRequests)
        files_query = Proc.new do
          ServiceResult.success(result: response)
        end
        allow(storage_requests).to receive(:files_query).and_return(files_query)
        allow(Storages::Peripherals::StorageRequests).to receive(:new).and_return(storage_requests)
      end

      subject { last_response.body }

      it 'responds with appropriate JSON' do
        expect(subject).to be_json_eql(response.files[0].id.to_json).at_path('files/0/id')
        expect(subject).to be_json_eql(response.files[0].name.to_json).at_path('files/0/name')
        expect(subject).to be_json_eql(response.files[1].id.to_json).at_path('files/1/id')
        expect(subject).to be_json_eql(response.files[1].name.to_json).at_path('files/1/name')
        expect(subject).to be_json_eql(response.files[0].permissions.to_json).at_path('files/0/permissions')
        expect(subject).to be_json_eql(response.files[1].permissions.to_json).at_path('files/1/permissions')
        expect(subject).to be_json_eql(response.parent.id.to_json).at_path('parent/id')
        expect(subject).to be_json_eql(response.parent.name.to_json).at_path('parent/name')
        expect(subject).to be_json_eql(response.ancestors.to_json).at_path('ancestors')
      end
    end

    context 'with query failed' do
      before do
        clazz = Storages::Peripherals::StorageInteraction::Nextcloud::FilesQuery
        instance = instance_double(clazz)
        allow(clazz).to receive(:new).and_return(instance)
        allow(instance).to receive(:call).and_return(
          ServiceResult.failure(result: error, errors: Storages::StorageError.new(code: error))
        )
      end

      context 'with authorization failure' do
        let(:error) { :not_authorized }

        it { expect(last_response.status).to be(500) }
      end

      context 'with internal error' do
        let(:error) { :error }

        it { expect(last_response.status).to be(500) }
      end

      context 'with not found' do
        let(:error) { :not_found }

        it 'fails with outbound request failure' do
          expect(last_response.status).to be(500)

          body = JSON.parse(last_response.body)
          expect(body['message']).to eq(I18n.t('api_v3.errors.code_500_outbound_request_failure', status_code: 404))
          expect(body['errorIdentifier']).to eq('urn:openproject-org:api:v3:errors:OutboundRequest:NotFound')
        end
      end
    end
  end

  describe 'POST /api/v3/storages/:storage_id/files/prepare_upload' do
    let(:permissions) { %i(view_work_packages view_file_links manage_file_links) }
    let(:path) { api_v3_paths.prepare_upload(storage.id) }
    let(:upload_link) { Storages::UploadLink.new('https://example.com/upload/xyz123') }
    let(:body) { { fileName: "ape.png", parent: "/Pictures", projectId: project.id }.to_json }

    subject(:last_response) do
      post(path, body)
    end

    describe 'with successful response' do
      before do
        clazz = Storages::Peripherals::StorageInteraction::Nextcloud::UploadLinkQuery
        instance = instance_double(clazz)
        allow(clazz).to receive(:new).and_return(instance)
        allow(instance).to receive(:call).and_return(ServiceResult.success(result: upload_link))
      end

      subject { last_response.body }

      it 'responds with appropriate JSON' do
        expect(subject).to be_json_eql(Storages::UploadLink.name.split('::').last.to_json).at_path('_type')
        expect(subject)
          .to(be_json_eql("#{API::V3::URN_PREFIX}storages:upload_link:no_link_provided".to_json)
                .at_path('_links/self/href'))
        expect(subject).to be_json_eql(upload_link.destination.to_json).at_path('_links/destination/href')
        expect(subject).to be_json_eql("post".to_json).at_path('_links/destination/method')
        expect(subject).to be_json_eql("Upload File".to_json).at_path('_links/destination/title')
      end
    end

    context 'with query failed' do
      before do
        clazz = Storages::Peripherals::StorageInteraction::Nextcloud::UploadLinkQuery
        instance = instance_double(clazz)
        allow(clazz).to receive(:new).and_return(instance)
        allow(instance).to receive(:call).and_return(
          ServiceResult.failure(result: error, errors: Storages::StorageError.new(code: error))
        )
      end

      describe 'due to authorization failure' do
        let(:error) { :not_authorized }

        it { expect(last_response.status).to be(500) }
      end

      describe 'due to internal error' do
        let(:error) { :error }

        it { expect(last_response.status).to be(500) }
      end

      describe 'due to not found' do
        let(:error) { :not_found }

        it 'fails with outbound request failure' do
          expect(last_response.status).to be(500)

          body = JSON.parse(last_response.body)
          expect(body['message']).to eq(I18n.t('api_v3.errors.code_500_outbound_request_failure', status_code: 404))
          expect(body['errorIdentifier']).to eq('urn:openproject-org:api:v3:errors:OutboundRequest:NotFound')
        end
      end
    end
  end
end
