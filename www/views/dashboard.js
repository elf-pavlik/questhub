pp.views.Dashboard = Backbone.View.extend({

    template: _.template($('script#template-dashboard').text()),

    initialize: function () {
        this.model = pp.app.user; // TODO - support viewing other users dashboard
    },

    // separate function because of ugly hack in router code, see router code
    start: function() {
        console.log("initialize dashboard");
        this.model.on('change', this.checkLogged, this);

        // see models/current-user.js for the explanation
        if (this.model.isFetched) {
            this.model.trigger('change');
        }
    },

    checkLogged: function() {
        console.log("checkLogged");
        if (!this.model.get("registered")) {
            console.log("not registered, back to welcome");
            pp.app.router.navigate("/#welcome", { trigger: true });
            return;
        }
        console.log("calling dashboard.render");
        this.render();
    },

    render: function() {
        console.log("dashboard.render");
        var login = this.model.get('login');

        // create self.openQuests and self.closedQuests
        var view = this;
        var statuses = ['open', 'closed'];
        _.each(['open', 'closed'], function(st) {
            var model = new pp.models.QuestCollection([], {
               'user': login,
               'status': st
            });
            model.fetch();
            view[st + 'Quests'] = new pp.views.QuestCollection({
                quests: model
            });
        });

        this.user = new pp.views.User({
            model: this.model
        });
        this.user.render();

        // self-render
        this.$el.html(this.template());
        this.$el.find('.open-quests').append(this.openQuests.$el);
        this.$el.find('.closed-quests').append(this.closedQuests.$el);
        this.$el.find('.user').append(this.user.$el);
    }
});