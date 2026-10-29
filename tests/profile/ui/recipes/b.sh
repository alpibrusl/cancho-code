# The stand-in unit agent's recipe for unit b of tests/profile/ui/plan.json: append the component Toggle to the entry ($1).
printf '\ncomponent Toggle {\n    state lit: Bool = false;\n    on Flip {\n        lit = !lit;\n    }\n    view {\n        Button {\n            label: "Flip"\n            on: Flip\n        }\n    }\n}\n' >> "$1"
