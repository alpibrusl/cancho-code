# The stand-in unit agent's recipe for unit a of tests/profile/ui/plan.json: append the component Counter to the entry ($1).
printf '\ncomponent Counter {\n    state count: Int = 0;\n    on Increment {\n        count = count + 1;\n    }\n    view {\n        Button {\n            label: "Increment"\n            on: Increment\n        }\n    }\n}\n' >> "$1"
