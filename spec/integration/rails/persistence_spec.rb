if ENV["APPRAISAL_INITIALIZED"]
  require 'rails_spec_helper'

  RSpec.describe 'persistence', type: :controller do
    include JsonHelpers

    controller(ApplicationController) do
      jsonapi resource: EmployeeResource

      # Avoid strong params / strong resource for this test
      def params
        @params ||= begin
          hash = super.to_unsafe_h.with_indifferent_access
          hash = hash[:params] if hash.has_key?(:params)
          hash
        end
      end

      def create
        employee, success = jsonapi_create.to_a

        if success
          render_jsonapi(employee, scope: false)
        else
          render json: { error: 'payload' }
        end
      end

      def update
        employee, success = jsonapi_update.to_a

        if success
          render_jsonapi(employee, scope: false)
        else
          render json: { error: 'payload' }
        end
      end

      def destroy
        employee, success = jsonapi_destroy.to_a

        if success
          render json: { meta: {} }
        else
          render json: { error: employee.errors }
        end
      end
    end

    def do_post
      post :create, params: payload
    end

    def do_put(id)
      put :update, params: payload
    end

    before do
      @request.headers['Accept'] = Mime[:json]
      @request.headers['Content-Type'] = Mime[:json].to_s

      routes.draw {
        post "create" => "anonymous#create"
        put "update" => "anonymous#update"
        delete "destroy" => "anonymous#destroy"
      }
    end

    describe 'basic create' do
      let(:payload) do
        {
          data: {
            type: 'employees',
            attributes: { first_name: 'Joe' }
          }
        }
      end

      it 'persists the employee' do
        expect {
          do_post
        }.to change { Employee.count }.by(1)
        employee = Employee.first
        expect(employee.first_name).to eq('Joe')
      end

      it 'responds with the persisted data' do
        do_post
        expect(json_item['id']).to eq(Employee.first.id.to_s)
      end

      context 'when validation error' do
        before do
          payload[:data][:attributes][:first_name] = nil
        end

        it 'returns validation error response' do
          do_post
          expect(json['error']).to eq('payload')
        end
      end
    end

    describe 'basic update' do
      let(:employee) { Employee.create(first_name: 'Joe') }

      let(:payload) do
        {
          data: {
            id: employee.id,
            type: 'employees',
            attributes: { first_name: 'Jane' }
          }
        }
      end

      it 'updates the data correctly' do
        expect {
          do_put(employee.id)
        }.to change { employee.reload.first_name }.from('Joe').to('Jane')
      end

      it 'responds with the persisted data' do
        do_put(employee.id)
        expect(json_item['id']).to eq(employee.id.to_s)
        expect(json_item['first_name']).to eq('Jane')
      end

      context 'when there is a validation error' do
        before do
          payload[:data][:attributes][:first_name] = nil
        end

        it 'responds with error' do
          do_put(employee.id)
          expect(json['error']).to eq('payload')
        end
      end
    end

    describe 'basic destroy' do
      let!(:employee) { Employee.create!(first_name: 'Joe') }

      before do
        allow_any_instance_of(Employee)
          .to receive(:force_validation_error) { force_validation_error }
      end

      let(:force_validation_error) { false }

      it 'deletes the object' do
        expect {
          delete :destroy, params: { id: employee.id }
        }.to change { Employee.count }.by(-1)
        expect { employee.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'responds with 200, empty meta' do
        delete :destroy, params: { id: employee.id }
        expect(response.status).to eq(200)
        expect(json).to eq({ 'meta' => {} })
      end

      context 'when validation errors' do
        let(:force_validation_error) { true }

        it 'responds with correct error payload' do
          expect {
            delete :destroy, params: { id: employee.id }
          }.to_not change { Employee.count }
          expect(json['error']).to eq('base' => ['Forced validation error'])
        end
      end
    end

    describe 'has_one nested relationship' do
      context 'for new records' do
        let(:payload) do
          {
            data: {
              type: 'employees',
              attributes: {
                first_name: 'Joe',
                last_name: 'Smith',
                age: 30
              },
              relationships: {
                salary: {
                  data: {
                    :'temp-id' => 'abc123',
                    type: 'salaries',
                    method: 'create'
                  },
                }
              }
            },
            included: [
              {
                :'temp-id' => 'abc123',
                type: 'salaries',
                attributes: {
                  base_rate: 15.00,
                  overtime_rate: 30.00
                }
              }
            ]
          }
        end

        it 'can create' do
          expect {
            do_post
          }.to change { Salary.count }.by(1)

          salary = Employee.first.salary
          expect(salary.base_rate).to eq(15.0)
          expect(salary.overtime_rate).to eq(30.0)
        end
      end

      context 'for existing records' do
        let(:employee) { Employee.create!(first_name: 'Joe') }
        let(:salary) { Salary.new(base_rate: 15.0, overtime_rate: 30.00) }

        before do
          employee.salary = salary
          employee.save!
        end

        context 'on update' do
          let(:payload) do
            {
              data: {
                id: employee.id,
                type: 'employees',
                relationships: {
                  salary: {
                    data: {
                      id: salary.id,
                      type: 'salaries',
                      method: 'update'
                    },
                  }
                }
              },
              included: [
                {
                  id: salary.id,
                  type: 'salaries',
                  attributes: {
                    base_rate: 15.75
                  }
                }
              ]
            }
          end

          it 'can update' do
            expect {
              do_put(employee.id)
            }.to change { employee.reload.salary.base_rate }.from(15.0).to(15.75)
          end
        end

        context 'on destroy' do
          let(:payload) do
            {
              data: {
                id: employee.id,
                type: 'employees',
                relationships: {
                  salary: {
                    data: {
                      id: salary.id,
                      type: 'salaries',
                      method: 'destroy'
                    }
                  }
                }
              }
            }
          end

          it 'can destroy' do
            do_put(employee.id)
            employee.reload

            expect(employee.salary).to be_nil
            expect { salary.reload }.to raise_error(ActiveRecord::RecordNotFound)
          end
        end

        context 'on disassociate' do
          let(:payload) do
            {
              data: {
                id: employee.id,
                type: 'employees',
                relationships: {
                  salary: {
                    data: {
                      id: salary.id,
                      type: 'salaries',
                      method: 'disassociate'
                    }
                  }
                }
              }
            }
          end

          it 'can disassociate' do
            do_put(employee.id)
            salary.reload

            expect(salary.employee_id).to be_nil
          end
        end
      end
    end

    describe 'has_and_belongs_to_many nested relationship' do
      let(:employee) { Employee.create!(first_name: 'Joe') }
      let(:prior_team) { Team.new(name: 'prior') }
      let(:disassociate_team) { Team.new(name: 'disassociate') }
      let(:destroy_team) { Team.new(name: 'destroy') }
      let(:associate_team) { Team.create!(name: 'preexisting') }

      before do
        employee.teams << prior_team
        employee.teams << disassociate_team
        employee.teams << destroy_team
      end

      let(:payload) do
        {
          data: {
            id: employee.id,
            type: 'employees',
            relationships: {
              teams: {
                data: [
                  { :'temp-id' => 'abc123', type: 'teams', method: 'create' },
                  { id: prior_team.id.to_s, type: 'teams', method: 'update' },
                  { id: disassociate_team.id.to_s, type: 'teams', method: 'disassociate' },
                  { id: destroy_team.id.to_s, type: 'teams', method: 'destroy' },
                  { id: associate_team.id.to_s, type: 'teams', method: 'update' }
                ]
              }
            }
          },
          included: [
            {
              :'temp-id' => 'abc123',
              type: 'teams',
              attributes: { name: 'Team #1' }
            },
            {
              id: prior_team.id.to_s,
              type: 'teams',
              attributes: { name: 'Updated!' }
            },
            {
              id: associate_team.id.to_s,
              type: 'teams'
            }
          ]
        }
      end

      it 'can create/update/disassociate/associate/destroy' do
        expect(employee.teams).to include(destroy_team)
        expect(employee.teams).to include(disassociate_team)
        do_put(employee.id)

        # Should properly delete/create from the through table
        combos = EmployeeTeam.all.map { |et| [et.employee_id, et.team_id] }
        expect(combos.uniq.length).to eq(combos.length)

        employee.reload
        expect(employee.teams).to_not include(disassociate_team)
        expect(employee.teams).to_not include(destroy_team)
        expect { disassociate_team.reload }.to_not raise_error
        expect { destroy_team.reload }.to raise_error(ActiveRecord::RecordNotFound)
        expect(prior_team.reload.name).to include('Updated!')
        expect(employee.teams).to include(associate_team)
        expect((employee.teams - [prior_team, associate_team]).first.name)
          .to eq('Team #1')
      end
    end

    describe 'nested polymorphic relationship' do
      let(:workspace_type) { 'offices' }

      let(:payload) do
        {
          data: {
            type: 'employees',
            attributes: { first_name: 'Joe' },
            relationships: {
              workspace: {
                data: {
                  :'temp-id' => 'work1', type: workspace_type, method: 'create'
                }
              }
            }
          },
          included: [
            {
              type: workspace_type,
              :'temp-id' => 'work1',
              attributes: {
                address: 'Fake Workspace Address'
              }
            }
          ]
        }
      end

      context 'with jsonapi type "offices"' do
        it 'associates workspace as office' do
          do_post
          employee = Employee.first
          expect(employee.workspace).to be_a(Office)
        end
      end

      context 'with jsonapi type "home_offices"' do
        let(:workspace_type) { 'home_offices' }

        it 'associates workspace as home office' do
          do_post
          employee = Employee.first
          expect(employee.workspace).to be_a(HomeOffice)
        end
      end

      it 'saves the relationship correctly' do
        expect {
          do_post
        }.to change { Employee.count }.by(1)
        employee = Employee.first
        workspace = employee.workspace
        expect(workspace.address).to eq('Fake Workspace Address')
      end
    end

    describe 'nested create' do
      let(:payload) do
        {
          data: {
            type: 'employees',
            attributes: { first_name: 'Joe' },
            relationships: {
              positions: {
                data: [
                  { type: 'positions', :'temp-id' => 'pos1', method: 'create' },
                  { type: 'positions', :'temp-id' => 'pos2', method: 'create' }
                ]
              }
            }
          },
          included: [
            {
              type: 'positions',
              :'temp-id' => 'pos1',
              attributes: { title: 'specialist' },
              relationships: {
                department: {
                  data: { type: 'departments', :'temp-id' => 'dep1', method: 'create' }
                }
              }
            },
            {
              type: 'departments',
              :'temp-id' => 'dep1',
              attributes: { name: 'safety' }
            },
            {
              type: 'positions',
              :'temp-id' => 'pos2',
              attributes: { title: 'manager' }
            }
          ]
        }
      end

      it 'creates the objects' do
        expect {
          do_post
        }.to change { Employee.count }.by(1)
        employee = Employee.first
        positions = employee.positions
        department = employee.positions[0].department

        expect(employee.first_name).to eq('Joe')
        expect(positions.length).to eq(2)
        expect(positions[0].title).to eq('specialist')
        expect(positions[1].title).to eq('manager')
        expect(department.name).to eq('safety')
      end

      context 'when associating to an existing record' do
        let!(:classification) { Classification.create!(description: 'senior') }

        let(:payload) do
          {
            data: {
              type: 'employees',
              attributes: { first_name: 'Joe' },
              relationships: {
                classification: {
                  data: {
                    type: 'classifications', id: classification.id.to_s
                  }
                }
              }
            }
          }
        end

        it 'associates to existing record' do
          do_post
          employee = Employee.first
          expect(employee.classification).to eq(classification)
        end
      end

      context 'when no method specified' do
        let!(:position) { Position.create!(title: 'specialist') }
        let!(:department) { Department.create!(name: 'safety') }

        let(:payload) do
          {
            data: {
              type: 'employees',
              attributes: { first_name: 'Joe' },
              relationships: {
                positions: {
                  data: [
                    { type: 'positions', id: position.id.to_s }
                  ]
                }
              }
            },
            included: [
              {
                type: 'positions',
                id: position.id.to_s,
                relationships: {
                  department: {
                    data: { type: 'departments', id: department.id, method: 'destroy' }
                  }
                }
              }
            ]
          }
        end

        it 'updates' do
          do_post
          position.reload
          employee = Employee.first
          expect(employee.positions[0]).to eq(position)
          expect(position.department_id).to be_nil
          expect { department.reload }.to raise_error(ActiveRecord::RecordNotFound)
        end
      end
    end

    describe 'nested update' do
      let!(:employee)   { Employee.create!(first_name: 'original', positions: [position1, position2]) }
      let!(:position1)  { Position.create!(title: 'unchanged') }
      let!(:position2)  { Position.create!(title: 'original', department: department) }
      let!(:department) { Department.create!(name: 'original') }

      let(:payload) do
        {
          data: {
            id: employee.id,
            type: 'employees',
            attributes: { first_name: 'updated first name' },
            relationships: {
              positions: {
                data: [
                  { type: 'positions', id: position2.id.to_s, method: 'update' }
                ]
              }
            }
          },
          included: [
            {
              type: 'positions',
              id: position2.id.to_s,
              attributes: { title: 'updated title' },
              relationships: {
                department: {
                  data: { type: 'departments', id: department.id.to_s, method: 'update' }
                }
              }
            },
            {
              type: 'departments',
              id: department.id.to_s,
              attributes: { name: 'updated name' }
            }
          ]
        }
      end

      it 'updates the objects' do
        do_put(employee.id)
        employee.reload
        expect(employee.first_name).to eq('updated first name')
        expect(employee.positions[0].title).to eq('unchanged')
        expect(employee.positions[1].title).to eq('updated title')
        expect(employee.positions[1].department.name).to eq('updated name')
      end

      # NB - should only sideload updated position, not all positions
      it 'sideloads the objects in response' do
        do_put(employee.id)
        expect(json_includes('positions').length).to eq(1)
        expect(json_includes('positions')[0]['id']).to eq(position2.id.to_s)
        expect(json_includes('departments').length).to eq(1)
      end
    end

    describe 'nested deletes' do
      let!(:employee)   { Employee.create!(first_name: 'Joe') }
      let!(:position)   { Position.create!(department_id: department.id, employee_id: employee.id) }
      let!(:department) { Department.create! }

      let(:payload) do
        {
          data: {
            id: employee.id,
            type: 'employees',
            attributes: { first_name: 'updated first name' },
            relationships: {
              positions: {
                data: [
                  { type: 'positions', id: position.id.to_s, method: method }
                ]
              }
            }
          },
          included: [
            {
              type: 'positions',
              id: position.id.to_s,
              relationships: {
                department: {
                  data: {
                    type: 'departments', id: department.id.to_s, method: method
                  }
                }
              }
            }
          ]
        }
      end

      context 'when disassociating' do
        let(:method) { 'disassociate' }

        it 'belongs_to: updates the foreign key on child' do
          expect {
            do_put(employee.id)
          }.to change { position.reload.department_id }.to(nil)
        end

        it 'has_many: updates the foreign key on the child' do
          expect {
            do_put(employee.id)
          }.to change { position.reload.employee_id }.to(nil)
        end

        it 'does not delete the objects' do
          do_put(employee.id)
          expect { position.reload }.to_not raise_error
          expect { department.reload }.to_not raise_error
        end

        it 'does not sideload the objects in the response' do
          do_put(employee.id)
          expect(json).to_not have_key('included')
        end
      end

      context 'when destroying' do
        let(:method) { 'destroy' }

        it 'deletes the objects' do
          do_put(employee.id)
          expect { position.reload }
            .to raise_error(ActiveRecord::RecordNotFound)
          expect { department.reload }
            .to raise_error(ActiveRecord::RecordNotFound)
        end

        it 'does not sideload the objects in the response' do
          do_put(employee.id)
          expect(json).to_not have_key('included')
        end
      end
    end
  end
end
