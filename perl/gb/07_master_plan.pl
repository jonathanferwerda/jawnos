package gb;
use strict;
no warnings;

#our $secret_maker = [&subs::random_string_creator(rand(130)),&subs::random_string_creator(rand(42)),&subs::random_string_creator(rand(420)), &subs::random_string_creator(rand(982)),&subs::random_string_creator(rand(436))];


our $master_plan = [
	{ team => 'President' },
	{ team => 'Offerings',
		clubs => [{
			team => 'Research',
			communities => [
				{ team => 'Internal Knowledge' }
			]
		},{
			team => 'Projects'
		},{
			team => 'Quality'
		},{
			team => 'Customer Service'
		},{
			team => 'Pricing',
			communities => [
				{ team => 'Formulas' }
			]
		},{
			team => 'Sales'
		}]
	},
	{ team => 'Organization',
		clubs => [{
			team => 'Location',
			communities => [
				{ team => 'Warehouse',
					projects => [ 'Inventory Controls', 'Stock Moves', 'Transportaion' ]
				},
				{ team => 'Waste Disposal',
					projects => [ 'bins' ]
				},
				{
					team => 'Offices',
					projects => [ 'Barns', 'Giant Whiteboards', 'Furniture',
						'Rent v. Buy', 'Number', 'Art', 'Decord', 'Work From Home',
						'Floor Plan'
					]
				},
				{
					team => 'Home Base'
				}
			]
		},{
			team => 'Corporate Culture',
			communities => [
				{ team => 'Recognition' },
				{ team => 'Express Love' },
				{ team => 'Meals' }
			]
		},{
			team => 'Chain of Command',
			communities => [
				{ team => 'My Roles',
					projects => [ 'Travelling', 'Retirement', 'Boundaries',
						'Fulfillment', 'Personal Goals', 'Management Style',
						'Speeches', 'Successor', 'Timeline', 'Vacations', 
						'Hours', 'Salary'
					]
				},
				{ team => 'Job Delegation' },
				{ team => 'Departments' }
			]
		},{
			team => 'Positions',
			communities => [
				{ team => 'Growth Transitions' },
				{ team => 'Graduating' }
			]
		}]
	},
	{ team => 'Systems',
		clubs => [{
			team => 'Code of Conduct',
			communities => [
				{ team => 'Conflict Resolution' }
			]
		},{
			team => 'I.T.',
			communities => [
				{ team => 'Computers' },
				{ team => 'Network' }
			]
		},{
			team => 'Time Management' 
		},{
			team => 'Ethical/Legal'
		},{
			team => 'Software',
			communities => [
				{ team => 'Design' },
				{ team => 'Capabilities' },
				{ team => 'Security' }
			]
		}]
	},
	{ team => 'Planning',
		clubs => [{
			team => 'Business Plan', 
			communities => [
				{ team => 'Scope' },
				{ team => 'Timeline' }
			]
		},{
			team => 'Mission',
			communities => [
				{ team => 'Competitive Advantages' },
				{ team => 'Value' }
			]
		},{
			team => 'Goals and Milestones',
			communities => [
				{ team => 'Measurement' },
				{ team => 'Revenue' },
				{ team => 'Forecasts',
					projects => [ 'employees', 'customers' ]
				},
				{ team => 'Growth' }
			]
		},{
			team => 'Budgeting'
		},{
			team => 'Disaster'
		},{
			community => 'Mentors'
		},{
			team => 'Fund Acquisition',
			communities => [
				{ team => 'Benefits' },
				{ team => 'Savings' },
				{ team => 'Loans',
					projects => [ 'Cost of Plan' ],
				}
			]
		}]
	},
	{ team => 'Operations',
		clubs => [{
			team => 'Purchasing',
			communities => [
				{ team => 'Replenish' },
				{ team => 'Suppliers' }
			]
		},{
			team => 'Administration',
			communities => [
				{ team => 'Collections' },
				{ team => 'Secretary' },
				{ team => 'Payroll' },
				{ team => 'Invoicing',
					projects => [ 'Utilities' ]
				}
			]
		},{
			team => 'Staff',
			communities => [
				{ team => 'Product' },
				{ team => 'Incentive Programs' },
				{ team => 'Benefit' },
				{ team => 'Scheduling' },
				{ team => 'HR' }
			]
		},{
			team => 'Training',
			communities => [
				{ team => 'Probation' },
				{ team => 'Apprenticeship' },
				{ team => 'Manuals' }
			]
		}]
	},
	{ team => 'Marketing',
		clubs => [{
			team => 'Our Customers',
			communities => [
				{ team => 'Community' }
			]
		},{
			team => 'Brand',
			communities => [
				{ team => 'Name' },
				{ team => 'CSR',
					projects => [ 'Classes' ]
				},
				{ team => 'Logo' }
			],
			projects => [ 'Psychographics' ]
		},{
			team => 'Communication',
			projects => [ 'Letterhead', 'Phones', 'Email' ]
		},{
			team => 'Web Presence',
			projects => [ 'Videohelp Forums', 'Blog' ],
		}, {
			team => 'Public Image',
			communities => [
				{ team => 'Trade Shows' },
				{ team => 'Punctuality' },
				{ team => 'Vehicles' },
				{ team => 'Briefcases' },
				{ team => 'Uniforms' }
			]
		}]
	},
	{ team => 'Financial/Legal',
		clubs => [{
			team => 'Debt/Asset'
		},{
			team => 'Terms of Use'
		},{
			team => 'Accounting',
			communities => [
				{ team => 'Book Keeping' },
				{ team => 'Tax' }
			]
		},{
			team => 'Wages',
			communities => [
				{ team => 'Contracts' },
				{ team => 'Employees' }
			]
		},{
			team => 'Insurance',
			communities => [
				{ team => 'Warranties' }
			]
		},{
			team => 'Cash Flow'
		},{
			team => 'Contracts'
		},{
			team => 'Pricing',
			communities => [
				{ team => 'Sales' },
				{ team => 'Formulas' }
			]
		}]
	},
	{ team => 'I.T. Services',
		communities => [
			{ team => 'Businesses' },
			{ team => 'Homes' },
			{ team => 'Appointments',
				projects => [ 'Punchclock', 'Maps' ]
			},
			{ team => 'Farms' }
		]
	},
	{ team => 'Server Software',
		communities => [
			{ team => 'Farms' },
			{ team => 'Bare Metal Dedi' },
			{ team => 'Databases' },
			{ team => 'Programming Services'}
		]
	},
	{ team => 'Embedded',
		communities => [
			{ team => 'SBC' },
			{ team => 'Wireless' },
			{ team => 'Circuits' },
			{ team => 'Sensors' },
			{ team => 'Interfaces' },
			{ team => 'Microcontrollers' }
		]
	}
];
