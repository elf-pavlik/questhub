package Play::Auth;

use Dancer ':syntax';
use Dancer::Plugin::Auth::Twitter;

use Play::Quests;
use Play::Mongo;

use Data::Dumper;
auth_twitter_init();

my $users = Play::Mongo->db->users;

prefix '/auth';

get '/twitter' => sub {
    if (not session('twitter_user')) {
        redirect auth_twitter_authenticate_url;
    } else {
        
        my $twitter_login = session->{twitter_user}->{screen_name};
        my $user = $users->find_one({twitter=>{login=>$twitter_login}});
        if ($user) {
            session 'login' => $user->{login};
        }
    	redirect "/";
    }
};

prefix '/api';


get '/user' => sub {

    my $constraints = {};
    if (request->params->{login}) {
         $constraints->{login} = request->params->{login};
    }
    if (request->params->{"twitter.login"}) {
         $constraints->{twitter}->{login} = request->params->{"twitter.login"};
    }
    
    unless (%$constraints) {
        $constraints->{login} = session->{login} or return { error => "not authorized" };
    }
    
    my $user = $users->find_one($constraints);
    unless ($user) {
        return { error => "not found" };
    }
    $user->{_id} = "$user->{_id}";
    return $user;
};

get '/session' => sub {
    return {%{session()}};
};

get '/new_login' => sub {
    if (not session('twitter_user')) {
        return { error => "not authorized" };
    }
    my $twitter_login = session('twitter_user')->{screen_name};
    my $login = request->params->{login};
    if ($users->find_one({login => $login})) {
        return { error => "Already exists" };
    }
    if ($users->find_one({twitter=>{login => $twitter_login}})) {
        return { error => "Already bound" };
    }
    my $user = {login => $login, twitter => {login => $twitter_login}};
    session 'login' => $login;
    $users->insert($user);
    return { status => "ok", user => $user };
};

get '/users' => sub {
    my @users = $users->find()->all;
    $_->{_id} = "$_->{_id}" for @users;
    return \@users;
};

# TODO - remove before going to production
get '/fakeuser/:login' => sub {
    my $login = param('login');
    session 'login' => $login;
    session 'twitter_user' => { screen_name => $login };

    my $user = { login => $login, twitter => { login => $login } };
    $users->insert($user);

    return { status => 'ok', user => $user };
};

true;
