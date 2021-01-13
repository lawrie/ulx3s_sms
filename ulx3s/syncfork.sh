#!/bin/sh
git remote add upstream https://github.com/lawrie/ulx3s_sms.git
git fetch upstream
git checkout master
git merge upstream/master

# to change already pushed commits to github
# git log
# git rebase -i <commit hex number here>
# git push origin +master
