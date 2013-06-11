#!/usr/bin/perl
use strict;
use warnings;
no warnings qw(uninitialized);

use DBI;
use DBIx::Pg::CallFunction;
use Test::More;
use Test::Deep;
use Data::Dumper;
use LWP::UserAgent;
use File::Slurp qw(write_file);

plan tests => 9;

# Connect to the isolated PCI compliant pci-blackbox
my $dbh_pci = DBI->connect("dbi:Pg:dbname=pci", '', '', {pg_enable_utf8 => 1, PrintError => 0});
my $pci = DBIx::Pg::CallFunction->new($dbh_pci);

# Connect to the normal database
my $dbh = DBI->connect("dbi:Pg:dbname=nonpci", '', '', {pg_enable_utf8 => 1, PrintError => 0});
my $nonpci = DBIx::Pg::CallFunction->new($dbh);

# Variables used throughout the test
my $cardnumber              = '5212345678901234';
my $cardexpirymonth         = 06;
my $cardexpiryyear          = 2016;
my $cardholdername          = 'Simon Hopper';
my $currencycode            = 'EUR';
my $paymentamount           = 20;
my $reference               = rand();
my $shopperip               = '1.2.3.4';
my $cardcvc                 = 737;
my $shopperemail            = 'test@test.com';
my $shopperreference        = rand();
my $http_accept             = 'text/html,application/xhtml+xml, application/xml;q=0.9,*/*;q=0.8';
my $http_user_agent         = 'Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9) Gecko/2008052912 Firefox/3.0';



# BEGIN (will ROLLBACK in the end of test)
$dbh_pci->begin_work();
$dbh->begin_work();



# Test 1, Get_Merchant_Account
my $merchant_account = $nonpci->get_merchant_account();
cmp_deeply(
    $merchant_account,
    {
        psp             => re('.+'),
        merchantaccount => re('.+'),
        url             => re('^https://'),
        username        => re('.+'),
        password        => re('.+')
    },
    'Get_Merchant_Account'
);



# Test 2, Encrypt_Card
my $encrypted_card = $pci->encrypt_card({
    _cardnumber      => $cardnumber,
    _cardexpirymonth => $cardexpirymonth,
    _cardexpiryyear  => $cardexpiryyear,
    _cardholdername  => $cardholdername,
    _cardissuenumber => undef,
    _cardstartmonth  => undef,
    _cardstartyear   => undef,
    _cardcvc         => $cardcvc
});
cmp_deeply(
    $encrypted_card,
    {
        cardnumberreference => re('^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'),
        cardkey             => re('^[0-9a-f]{64}$'),
        cardbin             => re('^[0-9]{6}$'),
        cardlast4           => re('^[0-9]{4}$'),
        cvckey              => re('^[0-9a-f]{64}$')
    },
    'Encrypt_Card'
);



# Test 3, Store_Card_Key
my $cardid = $nonpci->store_card_key({
    _cardnumberreference => $encrypted_card->{cardnumberreference},
    _cardkey             => $encrypted_card->{cardkey},
    _cardbin             => $encrypted_card->{cardbin},
    _cardlast4           => $encrypted_card->{cardlast4}
});
cmp_ok($cardid,'>=',1,"Store_Card_Key");

sub authorise {

    # Test 4, Authorise_Payment_Request
    my $request = {
        _cardkey                 => $encrypted_card->{cardkey},
        _cvckey                  => $encrypted_card->{cvckey},
        _psp                     => $merchant_account->{psp},
        _merchantaccount         => $merchant_account->{merchantaccount},
        _url                     => $merchant_account->{url},
        _username                => $merchant_account->{username},
        _password                => $merchant_account->{password},
        _currencycode            => $currencycode,
        _paymentamount           => $paymentamount,
        _reference               => $reference,
        _shopperip               => $shopperip,
        _shopperemail            => $shopperemail,
        _shopperreference        => $shopperreference,
        _http_accept             => $http_accept,
        _http_user_agent         => $http_user_agent
    };
    my $authorise_payment_response = $pci->authorise_payment_request($request);
    cmp_deeply(
        $authorise_payment_response,
        {
            'md'            => re('^[a-zA-Z0-9/+=]+$'),
            'authcode'      => undef,
            'pareq'         => re('^[a-zA-Z0-9/+=]+$'),
            'issuerurl'     => re('^https://'),
            'resultcode'    => 'RedirectShopper',
            'pspreference'  => re('^\d+$')
        },
        'Authorise_Payment_Request'
    );



    # Test 5, HTTPS POST issuer URL, load password form
    my $ua = LWP::UserAgent->new();
    my $http_response_load_password_form = $ua->post($authorise_payment_response->{issuerurl}, {
        PaReq   => $authorise_payment_response->{pareq},
        TermUrl => 'https://foo.bar.com/',
        MD      => $authorise_payment_response->{md}
    });
    ok($http_response_load_password_form->is_success, "HTTPS POST issuer URL, load password form");



    # Test 6, HTTPS POST issuer URL, submit password
    my $http_response_submit_password = $ua->post('https://test.adyen.com/hpp/3d/authenticate.shtml', {
        PaReq      => $authorise_payment_response->{pareq},
        TermUrl    => 'https://foo.bar.com/',
        MD         => $authorise_payment_response->{md},
        cardNumber => $cardnumber,
        username   => 'user',
        password   => 'password'
    });
    ok($http_response_submit_password->is_success, "HTTPS POST issuer URL, submit password");



    # Test 7, HTTPS POST issuer URL, parsed PaRes
    if ($http_response_submit_password->decoded_content =~ m/<input type="hidden" name="PaRes" value="([^"]+)"/) {
        ok(1,"HTTPS POST issuer URL, parsed PaRes");
    }
    my $pares = $1;



    # Test 8, Authorise_Payment_Request_3D
    my $request_3d = {
        _psp                     => $merchant_account->{psp},
        _merchantaccount         => $merchant_account->{merchantaccount},
        _url                     => $merchant_account->{url},
        _username                => $merchant_account->{username},
        _password                => $merchant_account->{password},
        _http_accept             => $http_accept,
        _http_user_agent         => $http_user_agent,
        _md                      => $authorise_payment_response->{md},
        _pares                   => $pares,
        _shopperip               => $shopperip
    };
    my $response_3d = $pci->authorise_payment_request_3d($request_3d);
    cmp_deeply(
        $response_3d,
        {
            'pspreference'  => re('^\d+$'),
            'resultcode'    => 'Authorised',
            'authcode'      => re('^\d+$')
        },
        'Authorise_Payment_Request_3D'
    );

    return $response_3d;

}




# Test 9, Capture_Payment_Request
my $response_3d = authorise();
my $capture_response = $nonpci->capture_payment_request({
    _psp                     => $merchant_account->{psp},
    _merchantaccount         => $merchant_account->{merchantaccount},
    _url                     => $merchant_account->{url},
    _username                => $merchant_account->{username},
    _password                => $merchant_account->{password},
    _currencycode            => $currencycode,
    _paymentamount           => $paymentamount,
    _pspreference            => $response_3d->{pspreference}
});
cmp_deeply(
    $capture_response,
    {
        'pspreference'  => re('^\d+$'),
        'response'      => '[capture-received]'
    },
    'Capture_Payment_Request'
);




# Test 10, Cancel_Payment_Request
$response_3d = authorise();
my $cancel_response = $nonpci->cancel_payment_request({
    _psp                     => $merchant_account->{psp},
    _merchantaccount         => $merchant_account->{merchantaccount},
    _url                     => $merchant_account->{url},
    _username                => $merchant_account->{username},
    _password                => $merchant_account->{password},
    _pspreference            => $response_3d->{pspreference}
});
cmp_deeply(
    $cancel_response,
    {
        'pspreference'  => re('^\d+$'),
        'response'      => '[cancel-received]'
    },
    'Cancel_Payment_Request'
);


$dbh->rollback;
$dbh_pci->rollback;
