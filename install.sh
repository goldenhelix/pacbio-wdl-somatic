mkdir -p "${WORKSPACE_DIR}/AppData/VarSeq/User Data/ProjectTemplates"

cp -f ./.project_templates/*.vsproject-template "${WORKSPACE_DIR}/AppData/VarSeq/User Data/ProjectTemplates"

git submodule update --init --recursive

echo "Installed VarSeq project templates"